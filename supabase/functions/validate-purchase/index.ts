import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { purchaseToken, productId } = await req.json()

    // Get the user from the JWT
    const authHeader = req.headers.get('Authorization')!
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    )

    const { data: { user }, error: authError } = await supabase.auth.getUser(
      authHeader.replace('Bearer ', '')
    )

    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // Verify with Google Play Developer API
    const packageName = 'com.iflixify.iflixify'
    const googleAccessToken = Deno.env.get('GOOGLE_PLAY_ACCESS_TOKEN')

    if (!googleAccessToken) {
      // Fallback: if no Google token, accept the purchase but log it
      console.warn('No GOOGLE_PLAY_ACCESS_TOKEN set, accepting purchase without verification')
      await supabase
        .from('profiles')
        .update({ tier: 'pro' })
        .eq('id', user.id)

      return new Response(
        JSON.stringify({ success: true, verified: false }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // Verify with Google Play
    const verifyUrl = `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${packageName}/purchases/products/${productId}/tokens/${purchaseToken}`

    const googleResponse = await fetch(verifyUrl, {
      headers: {
        'Authorization': `Bearer ${googleAccessToken}`,
      },
    })

    if (!googleResponse.ok) {
      return new Response(
        JSON.stringify({ error: 'Purchase verification failed' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const purchaseData = await googleResponse.json()

    // Check purchase state (0 = purchased, 1 = cancelled)
    if (purchaseData.purchaseState !== 0) {
      return new Response(
        JSON.stringify({ error: 'Purchase not active' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // Update user tier
    await supabase
      .from('profiles')
      .update({ tier: 'pro' })
      .eq('id', user.id)

    // Log the purchase
    await supabase
      .from('admin_audit_log')
      .insert({
        admin_id: user.id,
        action: 'purchase_verified',
        target: `${productId}:${purchaseToken.substring(0, 8)}...`,
      })

    return new Response(
      JSON.stringify({ success: true, verified: true }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  } catch (error) {
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})
