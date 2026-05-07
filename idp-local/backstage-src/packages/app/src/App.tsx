import { createApp } from '@backstage/frontend-defaults';

// New Backstage frontend system — plugins declared as dependencies in
// package.json are auto-discovered and registered without manual imports.
// Add @backstage/plugin-notifications to include notificationsApiRef impl.
export default createApp().createRoot();
