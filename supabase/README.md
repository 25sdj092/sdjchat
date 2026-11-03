# Supabase project files

This folder is the Supabase CLI project configuration and the source mirror of the deployed `send-push` Edge Function.

## Existing hosted project

- Project ref: `tunrakwqldpcxrtbdeuq`
- Project name: `supabase-blue-kite`
- Region: `us-east-1`
- PostgreSQL major version: `17`

The hosted database already contains the application schema, RLS policies, private `chat-images` bucket, Realtime publication, Vault settings, and five applied migration records. Do not run a schema setup script against that existing project.

The five migration records currently on the hosted project are:

- `20261102232426_sdjchat_supabase_chat_setup`
- `20261102232659_sdjchat_private_rls_helpers`
- `20261102232722_sdjchat_webpush_vault_config`
- `20261102233041_sdjchat_friend_code_rate_limit`
- `20261102233145_sdjchat_query_indexes`

**Important:** the original SQL bodies for those applied migrations have not yet been checked into this repository. This folder contains the CLI config and function source, not a complete clean-room database bootstrap. Do not use `supabase db reset` or point a new project at this repository expecting the database to be recreated.

## Edge Function

`functions/send-push/index.ts` mirrors the active hosted function. It uses the Supabase runtime-provided `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`, and stores VAPID secrets in Supabase Vault. Those secrets must never be copied into the browser bundle.

The function is configured with `verify_jwt = false` because it authenticates its two request paths itself:
- `public-key`: validates the caller's Supabase bearer token.
- notification delivery: validates the internal webhook secret stored in Vault.

To deploy an update intentionally:

```sh
supabase link --project-ref tunrakwqldpcxrtbdeuq
supabase functions deploy send-push --project-ref tunrakwqldpcxrtbdeuq
```

Deploying replaces the live function immediately. The current deployed function is already active; do not redeploy unless you have changed and reviewed the source.
