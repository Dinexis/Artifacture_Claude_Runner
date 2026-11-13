import { test, expect } from '@playwright/test';

const url = process.env.SMOKE_URL ?? 'https://example.com';

test(`headless Chromium erreicht ${url}`, async ({ page }) => {
  const response = await page.goto(url);
  expect(response?.status()).toBe(200);
  await expect(page.locator('h1').first()).toBeVisible();
});
