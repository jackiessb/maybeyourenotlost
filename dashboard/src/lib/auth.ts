export const LOGIN_URL = "/.auth/login/aad?post_login_redirect_uri=/";
export const LOGOUT_URL = "/.auth/logout?post_logout_redirect_uri=/";

export interface User {
  name: string;
}

interface EasyAuthClaim {
  typ: string;
  val: string;
}

interface EasyAuthPrincipal {
  user_id: string;
  provider_name: string;
  user_claims?: EasyAuthClaim[];
}

export function redirectToLogin() {
  window.location.href = LOGIN_URL;
}

/**
 * Asks Azure Container Apps Easy Auth who is signed in. Returns null when
 * nobody is. Easy Auth doesn't exist locally, so dev uses a fake user.
 */
export async function fetchCurrentUser(): Promise<User | null> {
  if (import.meta.env.DEV) {
    return { name: "Local Developer" };
  }

  try {
    const response = await fetch("/.auth/me");
    if (!response.ok) {
      return null;
    }
    const principals = (await response.json()) as EasyAuthPrincipal[];
    const principal = Array.isArray(principals) ? principals[0] : undefined;
    if (!principal) {
      return null;
    }
    const name = principal.user_claims?.find((c) => c.typ === "name")?.val;
    return { name: name || principal.user_id };
  } catch {
    return null;
  }
}
