# Tic Tac Toe — online, no sign-up

A single-file web game. Create a room, share a **5-character code**, and play from two phones or browsers. No accounts, no logins, no build step.

**Backend:** [Supabase](https://supabase.com) (Postgres + Realtime) · **Hosting:** [Vercel](https://vercel.com)

---

## How it works

| Piece | Detail |
| --- | --- |
| Identity | An anonymous UUID in `localStorage`. That's the whole "auth" story. |
| Room code | 5 chars from an unambiguous alphabet (`ABCDEFGHJKLMNPQRSTUVWXYZ23456789`), collision-checked on create. |
| Seats | Creator = `X`. First joiner = `O`. Everyone after that spectates. |
| Rules | Enforced in Postgres (`make_move`), not the browser — wins, turns, and occupied cells are validated server-side. |
| Sync | Supabase Realtime `postgres_changes` on the row, plus a 3s polling fallback for flaky networks. |
| Rematch | Either player resets the board; the loser of the previous round starts. |

### Data model

```sql
games(
  code text primary key,
  board jsonb,          -- 9 cells: "", "X", or "O"
  turn text,            -- 'X' | 'O'
  status text,          -- 'waiting' | 'playing' | 'done'
  winner text,          -- 'X' | 'O' | 'draw'
  winning_line jsonb,   -- e.g. [0,1,2] for the highlight
  x_player uuid,
  o_player uuid,
  moves int,
  created_at timestamptz,
  updated_at timestamptz
)
```

RLS is on: `SELECT` is open (you need the code to find a room), and **there are no INSERT/UPDATE/DELETE policies at all**. The only way to mutate a board is through the `SECURITY DEFINER` functions `new_game`, `join_game`, `make_move`, and `reset_game` — see [`supabase/schema.sql`](supabase/schema.sql).

## Run it locally

Static file, no build:

```bash
# any static server works
npx serve .
# or
python -m http.server 8000
```

Open `http://localhost:8000` in two different browsers (or one normal + one private window) so each gets its own player id.

## Deploy

Already live on Vercel. To redeploy after editing `index.html`:

```bash
npx vercel deploy --prod
```

## Notes / limits

- Rooms are never deleted. Add a cron janitor if you want to prune old games:
  `delete from public.games where updated_at < now() - interval '7 days';`
- Spectators can watch but not move; open the link in a private window to take the free seat.
- The board lives in one Postgres row, so all writes are naturally serialized by `SELECT ... FOR UPDATE`.
