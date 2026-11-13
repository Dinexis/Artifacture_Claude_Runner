import { defineConfig, devices } from '@playwright/test';

// Im Container mit wenig Speicher und dem Prozesslimit des Runners: 1 Worker, nur Chromium, headless.
export default defineConfig({
  testDir: '.',
  workers: 1,
  retries: 1,
  reporter: 'list',
  use: { headless: true },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
});
