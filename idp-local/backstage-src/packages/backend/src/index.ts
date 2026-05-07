import { createBackend } from '@backstage/backend-defaults';

const backend = createBackend();

// Core
backend.add(import('@backstage/plugin-app-backend'));
backend.add(import('@backstage/plugin-catalog-backend'));
backend.add(import('@backstage/plugin-catalog-backend-module-scaffolder-entity-model'));
backend.add(import('@backstage/plugin-scaffolder-backend'));
backend.add(import('@backstage/plugin-techdocs-backend'));

// Kubernetes plugin — reads cluster config from app-config.yaml kubernetes: section
backend.add(import('@backstage/plugin-kubernetes-backend'));

// Notifications — provides the REST API that backs notificationsApiRef in the
// frontend; without this the frontend throws NotImplementedError on page load.
backend.add(import('@backstage/plugin-notifications-backend'));

backend.start();
