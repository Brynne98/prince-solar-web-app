// What the plain scripts put on window for the app's modules: config.js (settings, PostHog),
// theme.js, and the Google and Cloudflare scripts. Module code shares nothing else through window.
export {};
declare global {
  interface Window {
    APP_VERSION: string;
    SUPPORT_EMAIL: string;
    GOOGLE_CLIENT_ID: string;
    VAPID_PUBLIC: string;
    TURNSTILE_SITE_KEY: string;
    SUNSYNK_CONFIG: { url: string; key: string };
    POSTHOG_KEY: string;
    CURRENT_PLANT: number | null;
    track(name: string, props?: Record<string, unknown>): void;
    identifyUser(id: string | null): void;
    reportClientError(err: unknown, props?: Record<string, unknown>): string | null;
    reportServerError(name: string, error: unknown, status?: number): string | null;
    lastErrorId?: { id: string; at: number };
    getTheme(): 'dark' | 'light' | 'device';
    setTheme(choice: 'dark' | 'light' | 'device'): void;
    google?: any;
    turnstile?: any;
  }
}
declare global {
  // Safari's names (wall display fullscreen)
  interface Document { webkitFullscreenElement?: Element | null; webkitExitFullscreen?: () => Promise<void> | void }
}
