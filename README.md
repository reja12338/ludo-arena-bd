# Ludo Arena BD — secure starter project

This starter includes a Next.js App Router + Supabase structure for:
- Supabase Auth (email/password starter)
- tournament listing
- manual payment claims (bKash/Nagad/Rocket merchant number + transaction ID)
- admin review workflow
- wallet ledger, prize credits and withdrawal requests
- PostgreSQL Row Level Security and database functions

## Important limits
This is a starter scaffold, not a deployed production service. Manual payment claims are NOT proof that money arrived. Admins must verify each transaction against the merchant account/provider records before approving. Do not accept screenshots alone as proof. Never store PINs, OTPs, passwords, or full payment credentials.

Before handling real money:
1. Verify that your tournament, entry-fee, prize and withdrawal model is permitted under applicable Bangladesh law and provider terms.
2. Use merchant accounts that explicitly allow this use case.
3. Configure at least two trusted admins, strong MFA, audit logs, backups, rate limits, monitoring, and support/dispute procedures.
4. Have the SQL and security reviewed before production.
5. Wallet balances are derived from an immutable ledger; never let clients set balances directly.

## Setup
1. Install Node.js 20+ and create a Supabase project.
2. Copy `.env.example` to `.env.local` and fill values.
3. In Supabase SQL Editor, run `supabase/schema.sql` as a project owner.
4. In Supabase Authentication settings, enable email/password and configure site URL / redirect URLs.
5. Create the first user using the app or Supabase Auth, then promote that user to admin using the SQL instructions below.
6. Install dependencies and run:
   ```bash
   npm install
   npm run dev
   ```
7. Open http://localhost:3000

## Promote an initial admin
After the user signs up, find their UUID in Supabase Authentication > Users. Then run in SQL Editor:
```sql
insert into public.user_roles (user_id, role)
values ('PASTE_AUTH_USER_UUID_HERE', 'admin')
on conflict (user_id) do update set role = 'admin';
```
Do this only for a trusted account you control. Never expose the service-role key in the browser.

## Manual payment flow
- Admin configures merchant number(s) and instructions in `payment_methods`.
- User creates a payment claim with method, amount, sender number and transaction ID.
- The claim remains `pending`; wallet is not credited yet.
- Admin independently checks the provider/merchant records, then approves or rejects.
- Approval runs a database function that prevents duplicate transaction IDs for a given provider and posts a ledger credit exactly once.

## Withdrawal flow
- User requests a withdrawal; the amount is reserved/debited from available balance atomically.
- Admin pays externally and marks it paid, or rejects it and the database returns the amount to the user's ledger.
- This scaffold deliberately does not send money automatically.

## Production TODOs
- Add CAPTCHA / rate limiting to auth and payment endpoints.
- Add admin MFA and audit logs.
- Add server-side pagination, notifications, support tickets, reconciliation reports.
- Add idempotent admin action audit records and approval separation for larger amounts.
- Consider using Supabase Edge Functions / server-only RPC calls for sensitive operations.
- Validate provider terms and local law before enabling cash prizes or cash withdrawals.
