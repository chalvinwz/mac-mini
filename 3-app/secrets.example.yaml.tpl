# Reference only — every key the application expects, with placeholder values. The real
# 3-app/05-secrets.yaml is a static file handed over out of band and is gitignored.
#
# The .tpl suffix is deliberate: `kubectl apply -f 3-app/` reads only .yaml/.yml/.json,
# so this file cannot be applied by accident and overwrite real credentials with ChangeMe.
---
apiVersion: v1
kind: Secret
metadata:
  name: planpal-db
  namespace: planpal
type: Opaque
stringData:
  POSTGRES_USER: ChangeMe
  POSTGRES_PASSWORD: ChangeMe
  POSTGRES_DB: ChangeMe
---
apiVersion: v1
kind: Secret
metadata:
  name: planpal-env
  namespace: planpal
type: Opaque
stringData:
  SECRET_DATABASE_URL: postgres://ChangeMe:ChangeMe@postgres:5432/ChangeMe
  SECRET_REDIS_URL: redis://redis:6379
  SECRET_JWT_SECRET: ChangeMe
  SECRET_GOOGLE_CLIENT_ID: ChangeMe
  SECRET_GOOGLE_CLIENT_SECRET: ChangeMe
  SECRET_SMTP_USERNAME: ChangeMe
  SECRET_SMTP_PASSWORD: ChangeMe
  SECRET_FCM_SERVICE_ACCOUNT_JSON: '{"type":"service_account","project_id":"ChangeMe"}'
  SECRET_SLACK_SIGNING_SECRET: ChangeMe
  SECRET_SLACK_BOT_TOKEN: ChangeMe
  SECRET_AI_API_KEY: ChangeMe
  APP__DATABASE__URL: postgres://ChangeMe:ChangeMe@postgres:5432/ChangeMe
  APP__EMAIL__PROVIDER: smtp
  APP__SMTP__HOST: smtp.gmail.com
  APP__SMTP__PORT: "587"
  APP__SMTP__FROM: PlanPal <ChangeMe@example.com>
  APP__AI__PROVIDER: ChangeMe
  APP__AI__MODEL_ID: ChangeMe
  APP__AI__API_BASE_URL: ChangeMe
---
apiVersion: v1
kind: Secret
metadata:
  name: planpal-seed-admin
  namespace: planpal
type: Opaque
stringData:
  SEED_ADMIN_EMAIL: admin@example.com
  SEED_ADMIN_PASSWORD: ChangeMe
  SEED_ADMIN_NAME: System Admin
---
apiVersion: v1
kind: Secret
metadata:
  name: planpal-web-env
  namespace: planpal
type: Opaque
stringData:
  SECRET_SOURCE: env
  SECRET_PATH: planpal/production
  SECRET_FIREBASE_API_KEY: ChangeMe
  SECRET_FIREBASE_AUTH_DOMAIN: ChangeMe
  SECRET_FIREBASE_PROJECT_ID: ChangeMe
  SECRET_FIREBASE_STORAGE_BUCKET: ChangeMe
  SECRET_FIREBASE_MESSAGING_SENDER_ID: ChangeMe
  SECRET_FIREBASE_APP_ID: ChangeMe
  SECRET_FIREBASE_MEASUREMENT_ID: ChangeMe
  SECRET_FIREBASE_VAPID_KEY: ChangeMe
