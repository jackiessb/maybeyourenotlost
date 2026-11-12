import { redirectToLogin } from "./auth";

export const EncouragementStatus = {
  Waiting: -1,
  Rejected: 0,
  Approved: 1,
} as const;

export type EncouragementStatus =
  (typeof EncouragementStatus)[keyof typeof EncouragementStatus];

export interface Encouragement {
  id: number;
  text: string;
  status: EncouragementStatus;
}

export class ApiError extends Error {
  readonly status: number;
  readonly validationErrors: Record<string, string[]>;

  constructor(
    message: string,
    status: number,
    validationErrors: Record<string, string[]> = {},
  ) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.validationErrors = validationErrors;
  }
}

async function request<T>(url: string, init?: RequestInit): Promise<T> {
  let response: Response;
  try {
    response = await fetch(url, {
      ...init,
      headers: { "Content-Type": "application/json", ...init?.headers },
    });
  } catch {
    throw new ApiError("Could not reach the server.", 0);
  }

  if (response.status === 401 || response.status === 403) {
    redirectToLogin();
    throw new ApiError("Your session has expired.", response.status);
  }

  if (response.status === 404) {
    throw new ApiError("That item no longer exists.", 404);
  }

  if (response.status === 400) {
    let errors: Record<string, string[]> = {};
    try {
      const body = (await response.json()) as {
        errors?: Record<string, string[]>;
      };
      errors = body.errors ?? {};
    } catch {
      // Not a ValidationProblem body; fall through with no field errors.
    }
    throw new ApiError("Please fix the errors and try again.", 400, errors);
  }

  if (!response.ok) {
    throw new ApiError(
      `Request failed with status ${response.status}.`,
      response.status,
    );
  }

  if (response.status === 204) {
    return undefined as T;
  }
  return (await response.json()) as T;
}

/** Field errors from a 400 response, matched case-insensitively by field name. */
export function getFieldErrors(error: unknown, field: string): string[] {
  if (!(error instanceof ApiError)) {
    return [];
  }
  const key = Object.keys(error.validationErrors).find(
    (k) => k.toLowerCase() === field.toLowerCase(),
  );
  return key ? error.validationErrors[key] : [];
}

export function getErrorMessage(error: unknown) {
  return error instanceof Error ? error.message : "Something went wrong.";
}

export const getEncouragements = () =>
  request<Encouragement[]>("/admin/encouragements");

export const updateEncouragement = (id: number, text: string) =>
  request<Encouragement>(`/admin/encouragements/${id}`, {
    method: "PUT",
    body: JSON.stringify({ text }),
  });

export const setEncouragementStatus = (
  id: number,
  status: EncouragementStatus,
) =>
  request<Encouragement>(`/admin/encouragements/${id}/status`, {
    method: "PUT",
    body: JSON.stringify({ status }),
  });

export const deleteEncouragement = (id: number) =>
  request<void>(`/admin/encouragements/${id}`, { method: "DELETE" });
