"use client";

import { useEffect, useState } from "react";
import { useParams } from "next/navigation";
import { supabase } from "@/lib/supabase";

interface UserProfile {
  id: string;
  email: string;
  full_name: string | null;
  tier: string;
  is_admin: boolean;
  created_at: string;
  updated_at: string;
}

interface License {
  id: string;
  license_key: string;
  status: string;
  granted_at: string;
  expires_at: string | null;
}

interface Device {
  id: string;
  device_name: string;
  device_type: string;
  is_active: boolean;
  last_seen_at: string;
  created_at: string;
}

export default function UserDetailPage() {
  const params = useParams();
  const userId = params?.id as string;
  const [user, setUser] = useState<UserProfile | null>(null);
  const [license, setLicense] = useState<License | null>(null);
  const [devices, setDevices] = useState<Device[]>([]);
  const [loading, setLoading] = useState(true);
  const [updating, setUpdating] = useState(false);

  useEffect(() => {
    if (!userId) return;

    async function fetchUser() {
      const { data: profile } = await supabase
        .from("profiles")
        .select("*")
        .eq("id", userId)
        .single();

      setUser(profile);

      const { data: lic } = await supabase
        .from("licenses")
        .select("*")
        .eq("user_id", userId)
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle();

      setLicense(lic);

      const { data: devs } = await supabase
        .from("devices")
        .select("*")
        .eq("user_id", userId)
        .order("created_at", { ascending: false });

      setDevices(devs ?? []);
      setLoading(false);
    }

    fetchUser();
  }, [userId]);

  const updateTier = async (newTier: string) => {
    if (!user) return;
    setUpdating(true);
    await supabase.from("profiles").update({ tier: newTier }).eq("id", user.id);
    const { data: { user: adminUser } } = await supabase.auth.getUser();
    await supabase.from("admin_audit_log").insert({
      admin_id: adminUser?.id,
      action: "tier_change",
      target: `user:${user.id}`,
      details: `Changed tier from ${user.tier} to ${newTier}`,
    });
    setUser({ ...user, tier: newTier });
    setUpdating(false);
  };

  const revokeLicense = async () => {
    if (!license) return;
    setUpdating(true);
    await supabase.from("licenses").update({ status: "revoked" }).eq("id", license.id);
    const { data: { user: adminUser } } = await supabase.auth.getUser();
    await supabase.from("admin_audit_log").insert({
      admin_id: adminUser?.id,
      action: "license_revoked",
      target: `license:${license.id}`,
      details: `Revoked license for user ${userId}`,
    });
    setLicense({ ...license, status: "revoked" });
    setUpdating(false);
  };

  const toggleDevice = async (deviceId: string, currentActive: boolean) => {
    setUpdating(true);
    await supabase.from("devices").update({ is_active: !currentActive }).eq("id", deviceId);
    setDevices((prev) =>
      prev.map((d) => (d.id === deviceId ? { ...d, is_active: !currentActive } : d))
    );
    setUpdating(false);
  };

  if (loading) {
    return (
      <div style={{ padding: 32, maxWidth: 900, margin: "0 auto" }}>
        <p style={{ color: "var(--text-muted)" }}>Loading user...</p>
      </div>
    );
  }

  if (!user) {
    return (
      <div style={{ padding: 32, maxWidth: 900, margin: "0 auto" }}>
        <p style={{ color: "var(--danger)" }}>User not found</p>
      </div>
    );
  }

  return (
    <div style={{ padding: 32, maxWidth: 900, margin: "0 auto" }}>
      {/* Header */}
      <div style={{ marginBottom: 32 }}>
        <a href="/users" style={{ color: "var(--text-muted)", fontSize: 13, textDecoration: "none" }}>
          &larr; Back to Users
        </a>
        <h1 style={{ fontSize: 28, fontWeight: 700, marginTop: 8 }}>{user.email}</h1>
        <p style={{ color: "var(--text-secondary)", marginTop: 4 }}>
          {user.full_name || "No name set"} &middot; Joined {new Date(user.created_at).toLocaleDateString()}
        </p>
      </div>

      {/* Profile Card */}
      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 24, marginBottom: 24 }}>
        <div style={{ background: "var(--bg-card)", border: "1px solid var(--border)", borderRadius: 12, padding: 24 }}>
          <h2 style={{ fontSize: 16, fontWeight: 600, marginBottom: 16 }}>Profile</h2>
          <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
            <div style={{ display: "flex", justifyContent: "space-between" }}>
              <span style={{ color: "var(--text-muted)", fontSize: 14 }}>Email</span>
              <span style={{ fontSize: 14 }}>{user.email}</span>
            </div>
            <div style={{ display: "flex", justifyContent: "space-between" }}>
              <span style={{ color: "var(--text-muted)", fontSize: 14 }}>Name</span>
              <span style={{ fontSize: 14 }}>{user.full_name || "-"}</span>
            </div>
            <div style={{ display: "flex", justifyContent: "space-between" }}>
              <span style={{ color: "var(--text-muted)", fontSize: 14 }}>Tier</span>
              <span style={{ fontSize: 14, fontWeight: 600, color: user.tier === "pro" ? "var(--warning)" : "var(--text-secondary)" }}>
                {user.tier.toUpperCase()}
              </span>
            </div>
            <div style={{ display: "flex", justifyContent: "space-between" }}>
              <span style={{ color: "var(--text-muted)", fontSize: 14 }}>Admin</span>
              <span style={{ fontSize: 14, color: user.is_admin ? "var(--accent)" : "var(--text-muted)" }}>
                {user.is_admin ? "Yes" : "No"}
              </span>
            </div>
          </div>

          {/* Tier Actions */}
          <div style={{ marginTop: 20, borderTop: "1px solid var(--border)", paddingTop: 16 }}>
            <p style={{ fontSize: 12, color: "var(--text-muted)", marginBottom: 8 }}>Change Tier</p>
            <div style={{ display: "flex", gap: 8 }}>
              {["free", "pro"].map((t) => (
                <button
                  key={t}
                  onClick={() => updateTier(t)}
                  disabled={user.tier === t || updating}
                  style={{
                    padding: "6px 16px",
                    background: user.tier === t ? "var(--accent)" : "var(--bg-hover)",
                    color: user.tier === t ? "#fff" : "var(--text-secondary)",
                    border: "1px solid var(--border)",
                    borderRadius: 6,
                    fontSize: 13,
                    cursor: user.tier === t ? "default" : "pointer",
                    opacity: user.tier === t ? 0.6 : 1,
                  }}
                >
                  {t === "free" ? "Free" : "Pro"}
                </button>
              ))}
            </div>
          </div>
        </div>

        {/* License Card */}
        <div style={{ background: "var(--bg-card)", border: "1px solid var(--border)", borderRadius: 12, padding: 24 }}>
          <h2 style={{ fontSize: 16, fontWeight: 600, marginBottom: 16 }}>License</h2>
          {!license ? (
            <p style={{ color: "var(--text-muted)", fontSize: 14 }}>No license found</p>
          ) : (
            <>
              <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
                <div style={{ display: "flex", justifyContent: "space-between" }}>
                  <span style={{ color: "var(--text-muted)", fontSize: 14 }}>Key</span>
                  <span style={{ fontSize: 13, fontFamily: "monospace" }}>{license.license_key.slice(0, 8)}...</span>
                </div>
                <div style={{ display: "flex", justifyContent: "space-between" }}>
                  <span style={{ color: "var(--text-muted)", fontSize: 14 }}>Status</span>
                  <span
                    style={{
                      fontSize: 13,
                      fontWeight: 600,
                      color: license.status === "active" ? "var(--success)" : "var(--danger)",
                    }}
                  >
                    {license.status}
                  </span>
                </div>
                <div style={{ display: "flex", justifyContent: "space-between" }}>
                  <span style={{ color: "var(--text-muted)", fontSize: 14 }}>Granted</span>
                  <span style={{ fontSize: 13 }}>{new Date(license.granted_at).toLocaleDateString()}</span>
                </div>
                {license.expires_at && (
                  <div style={{ display: "flex", justifyContent: "space-between" }}>
                    <span style={{ color: "var(--text-muted)", fontSize: 14 }}>Expires</span>
                    <span style={{ fontSize: 13 }}>{new Date(license.expires_at).toLocaleDateString()}</span>
                  </div>
                )}
              </div>
              {license.status === "active" && (
                <button
                  onClick={revokeLicense}
                  disabled={updating}
                  style={{
                    marginTop: 16,
                    padding: "8px 16px",
                    background: "var(--danger)",
                    color: "#fff",
                    border: "none",
                    borderRadius: 6,
                    fontSize: 13,
                    cursor: "pointer",
                  }}
                >
                  Revoke License
                </button>
              )}
            </>
          )}
        </div>
      </div>

      {/* Devices */}
      <div style={{ background: "var(--bg-card)", border: "1px solid var(--border)", borderRadius: 12, padding: 24 }}>
        <h2 style={{ fontSize: 16, fontWeight: 600, marginBottom: 16 }}>Devices ({devices.length})</h2>
        {devices.length === 0 ? (
          <p style={{ color: "var(--text-muted)", fontSize: 14 }}>No devices registered</p>
        ) : (
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            {devices.map((d) => (
              <div
                key={d.id}
                style={{
                  display: "flex",
                  justifyContent: "space-between",
                  alignItems: "center",
                  padding: "12px 16px",
                  background: "var(--bg-hover)",
                  borderRadius: 8,
                }}
              >
                <div>
                  <span style={{ fontWeight: 500, fontSize: 14 }}>{d.device_name || "Unknown Device"}</span>
                  <span style={{ color: "var(--text-muted)", fontSize: 12, marginLeft: 8 }}>{d.device_type}</span>
                </div>
                <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
                  <span
                    style={{
                      fontSize: 11,
                      fontWeight: 600,
                      color: d.is_active ? "var(--success)" : "var(--danger)",
                      textTransform: "uppercase",
                    }}
                  >
                    {d.is_active ? "Active" : "Inactive"}
                  </span>
                  <button
                    onClick={() => toggleDevice(d.id, d.is_active)}
                    disabled={updating}
                    style={{
                      padding: "4px 12px",
                      background: d.is_active ? "var(--danger)" : "var(--success)",
                      color: "#fff",
                      border: "none",
                      borderRadius: 4,
                      fontSize: 12,
                      cursor: "pointer",
                    }}
                  >
                    {d.is_active ? "Deactivate" : "Activate"}
                  </button>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
