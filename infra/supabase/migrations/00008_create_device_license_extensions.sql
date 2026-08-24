-- Device license extensions allow users to purchase additional device slots
CREATE TABLE IF NOT EXISTS public.device_license_extensions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  additional_devices integer NOT NULL DEFAULT 0,
  purchased_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz,
  PRIMARY KEY (id)
);

ALTER TABLE public.device_license_extensions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own device extensions"
  ON public.device_license_extensions FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Service role can manage device extensions"
  ON public.device_license_extensions FOR ALL
  USING (true)
  WITH CHECK (true);
