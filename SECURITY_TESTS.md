# RLS attack checklist

Run `schema.sql` as one script in a blank Supabase project. It seeds
`212161f@gmail.com` as manager at that account's first Auth sign-up; all other
new accounts are created as pending. This is a single-household model: approved
members share one inventory, while pending users can see only their own role
and no household inventory or other member.

| Attack attempt | Expected result | Database defence |
| --- | --- | --- |
| Sign up with any email and try to insert/update a `members` row with `role = 'manager'` | Denied. | There is no client `INSERT` policy on `members`; `managers manage members` requires `app_private.is_manager()`. The Auth trigger is the only creation path and assigns `pending` except for the exact seeded owner email. |
| Sign up through a non-email Auth provider or phone login | A membership row is still created as `pending`. | The trigger stores a blank email when Auth supplies none; only the exact configured Gmail receives `manager`. |
| Change `user_metadata.role` in the browser, forge a JWT field, or call the REST API directly | Still pending and denied. | Policies read `public.members` through `app_private.current_member_role()`, never JWT/user metadata. |
| As pending, select `records` or another member's row | Returns no rows; selecting the caller's own membership row returns only that row so the app can show `pending`. | `approved members read inventory` requires manager, clerk, or viewer. `members read own role` is restricted to `user_id = auth.uid()`. |
| As viewer (親友), POST/PATCH/DELETE a record | Denied. | All three write policies require `app_private.can_write_records()`, which only accepts manager or clerk. |
| As clerk, submit `created_by` equal to a manager's UUID on INSERT | Stored value is the caller's `auth.uid()`, not the supplied UUID. | `protect_record_attribution` overwrites `NEW.created_by` in its `BEFORE INSERT` branch. |
| PATCH an existing record and replace `created_by` | Statement errors and rolls back. | `protect_record_attribution` raises `created_by is immutable` whenever the value differs from `OLD.created_by`. |
| Use the anonymous key or an expired/no token | Denied. | Every policy is `TO authenticated`; the insert trigger additionally rejects a null `auth.uid()`. |
| Call private role helper functions through the Data API | Not exposed as a public API surface. | They are in `app_private`, whose schema is not exposed; access is restricted to authenticated callers only for policy evaluation. |

## Acceptance tests after deployment

1. Sign up as the configured owner Gmail: confirm a `members` row appears as
   `manager` with `approved_at` set.
2. Sign up as a second account: confirm it can read only its own `pending`
   membership row, `records` returns no data, and record inserts fail.
3. Using the manager session, set the second account to `clerk` and set
   `approved_at = now()`. Confirm it can read and create records, but that a
   supplied `created_by` is overwritten with its own Auth UUID.
4. Promote a third account to `viewer`; confirm it can read but cannot mutate.
5. Try `update public.records set created_by = '<different UUID>'`; confirm the
   trigger error occurs and the row remains unchanged.

Keep the Supabase `service_role`/secret key on a trusted server only. It can
bypass RLS by design and must never be shipped in the browser.
