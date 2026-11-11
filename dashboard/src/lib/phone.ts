const US_NUMBER_LENGTH = 10;

/** Keeps only the digits a US subscriber number can be built from. */
function getDigits(value: string) {
  const digits = value.replace(/\D/g, "");
  // A leading "1" is the country code, not part of the 10-digit number.
  if (digits.length > US_NUMBER_LENGTH && digits.startsWith("1")) {
    return digits.slice(1, US_NUMBER_LENGTH + 1);
  }
  return digits.slice(0, US_NUMBER_LENGTH);
}

/** Formats what the user has typed so far as (123) 456-7890. */
export function formatPhoneNumber(value: string) {
  const digits = getDigits(value);
  if (digits.length <= 3) {
    return digits;
  }
  if (digits.length <= 6) {
    return `(${digits.slice(0, 3)}) ${digits.slice(3)}`;
  }
  return `(${digits.slice(0, 3)}) ${digits.slice(3, 6)}-${digits.slice(6)}`;
}

/**
 * Converts a typed US phone number into E.164 (+14255550123), or returns null
 * when it isn't a valid one. Area code and exchange code must start with 2-9,
 * per the North American Numbering Plan.
 */
export function toE164(value: string) {
  const digits = getDigits(value);
  if (!/^[2-9]\d{2}[2-9]\d{6}$/.test(digits)) {
    return null;
  }
  return `+1${digits}`;
}
