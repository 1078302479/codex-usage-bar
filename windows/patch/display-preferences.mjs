import { readFile } from 'node:fs/promises';

export function displayPreferences(value) {
  const showShort = value?.showShort !== false;
  const showWeekly = value?.showWeekly !== false;
  const showResetCredits = value?.showResetCredits !== false;
  return {
    showShort,
    showWeekly,
    showResetTimes: (showShort || showWeekly) && value?.showResetTimes !== false,
    showResetCredits,
    expandCards: showResetCredits && value?.expandCards !== false,
  };
}

export async function readDisplayPreferences(path) {
  try {
    return displayPreferences(JSON.parse(await readFile(path, 'utf8')));
  } catch (error) {
    if (error.code === 'ENOENT' || error instanceof SyntaxError) return displayPreferences();
    throw error;
  }
}
