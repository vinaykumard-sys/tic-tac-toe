-- Tic Tac Toe — Supabase schema
-- Applied to project hurdcuilcplmpipresqx (tic-tac-toe, ap-south-1)
--
-- Design notes:
--   * No accounts. A player is an anonymous UUID kept in localStorage.
--   * Clients can only SELECT. Every write goes through a SECURITY DEFINER
--     function that validates seat, turn, and cell, so the board can't be
--     tampered with by crafting a REST call.
--   * Rows are real-time published for instant board sync.

create table if not exists public.games (
  code          text primary key,
  board         jsonb not null default '["","","","","","","","",""]'::jsonb,
  turn          text  not null default 'X' check (turn in ('X','O')),
  status        text  not null default 'waiting' check (status in ('waiting','playing','done')),
  winner        text  check (winner in ('X','O','draw')),
  winning_line  jsonb,
  x_player      uuid,
  o_player      uuid,
  moves         int   not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

alter table public.games enable row level security;

-- Board state is public knowledge for anyone holding the 5-char code.
drop policy if exists "games are public readable" on public.games;
create policy "games are public readable" on public.games
  for select to anon, authenticated using (true);

-- Realtime
alter table public.games replica identity full;
do $$
begin
  alter publication supabase_realtime add table public.games;
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------- new_game
create or replace function public.new_game(p_player uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_code text;
  v_row  public.games;
begin
  loop
    v_code := (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', (floor(random()*32)+1)::int, 1), '')
               from generate_series(1,5));
    exit when not exists (select 1 from public.games where code = v_code);
  end loop;

  insert into public.games (code, x_player) values (v_code, p_player)
  returning * into v_row;

  return to_jsonb(v_row);
end $$;

-- --------------------------------------------------------------- join_game
-- First caller becomes O. Rejoining is idempotent. Extra callers spectate.
create or replace function public.join_game(p_code text, p_player uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  g public.games;
  v_code text := upper(trim(p_code));
begin
  select * into g from public.games where code = v_code for update;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;

  if g.x_player = p_player or g.o_player = p_player then
    return to_jsonb(g);
  end if;

  if g.o_player is null then
    update public.games
       set o_player = p_player,
           status = case when status = 'waiting' then 'playing' else status end,
           updated_at = now()
     where code = v_code
     returning * into g;
  end if;

  return to_jsonb(g);
end $$;

-- --------------------------------------------------------------- make_move
create or replace function public.make_move(p_code text, p_player uuid, p_cell int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  g public.games;
  v_mark  text;
  v_board jsonb;
  v_line  jsonb := null;
  v_win   text  := null;
  v_code  text := upper(trim(p_code));
begin
  if p_cell < 0 or p_cell > 8 then raise exception 'BAD_CELL'; end if;

  select * into g from public.games where code = v_code for update;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  if g.status = 'waiting' then raise exception 'WAITING_FOR_OPPONENT'; end if;
  if g.status = 'done'   then raise exception 'GAME_OVER'; end if;

  if g.x_player = p_player then v_mark := 'X';
  elsif g.o_player = p_player then v_mark := 'O';
  else raise exception 'NOT_A_PLAYER'; end if;

  if v_mark <> g.turn then raise exception 'NOT_YOUR_TURN'; end if;
  if coalesce(g.board->>p_cell, '') <> '' then raise exception 'CELL_TAKEN'; end if;

  v_board := jsonb_set(g.board, array[p_cell::text], to_jsonb(v_mark));

  if    v_board->>0 = v_mark and v_board->>1 = v_mark and v_board->>2 = v_mark then v_line := '[0,1,2]';
  elsif v_board->>3 = v_mark and v_board->>4 = v_mark and v_board->>5 = v_mark then v_line := '[3,4,5]';
  elsif v_board->>6 = v_mark and v_board->>7 = v_mark and v_board->>8 = v_mark then v_line := '[6,7,8]';
  elsif v_board->>0 = v_mark and v_board->>3 = v_mark and v_board->>6 = v_mark then v_line := '[0,3,6]';
  elsif v_board->>1 = v_mark and v_board->>4 = v_mark and v_board->>7 = v_mark then v_line := '[1,4,7]';
  elsif v_board->>2 = v_mark and v_board->>5 = v_mark and v_board->>8 = v_mark then v_line := '[2,5,8]';
  elsif v_board->>0 = v_mark and v_board->>4 = v_mark and v_board->>8 = v_mark then v_line := '[0,4,8]';
  elsif v_board->>2 = v_mark and v_board->>4 = v_mark and v_board->>6 = v_mark then v_line := '[2,4,6]';
  end if;

  if v_line is not null then
    v_win := v_mark;
  elsif g.moves + 1 = 9 then
    v_win := 'draw';
  end if;

  update public.games
     set board        = v_board,
         moves        = moves + 1,
         turn         = case when v_win is null
                             then (case when v_mark = 'X' then 'O' else 'X' end)
                             else turn end,
         winner       = v_win,
         winning_line = v_line,
         status       = case when v_win is not null then 'done' else status end,
         updated_at   = now()
   where code = v_code
   returning * into g;

  return to_jsonb(g);
end $$;

-- -------------------------------------------------------------- reset_game
-- Rematch. Loser (or the non-starter on a draw) opens the next round.
create or replace function public.reset_game(p_code text, p_player uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  g public.games;
  v_code text := upper(trim(p_code));
  v_turn text;
begin
  select * into g from public.games where code = v_code for update;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;

  if g.x_player <> p_player
     and coalesce(g.o_player, '00000000-0000-0000-0000-000000000000'::uuid) <> p_player then
    raise exception 'NOT_A_PLAYER';
  end if;

  v_turn := case when g.winner = 'X' then 'O'
                 when g.winner = 'O' then 'X'
                 else g.turn end;

  update public.games
     set board        = '["","","","","","","","",""]'::jsonb,
         moves        = 0,
         turn         = v_turn,
         winner       = null,
         winning_line = null,
         status       = case when o_player is null then 'waiting' else 'playing' end,
         updated_at   = now()
   where code = v_code
   returning * into g;

  return to_jsonb(g);
end $$;

grant execute on function public.new_game(uuid)              to anon, authenticated;
grant execute on function public.join_game(text, uuid)       to anon, authenticated;
grant execute on function public.make_move(text, uuid, int)  to anon, authenticated;
grant execute on function public.reset_game(text, uuid)      to anon, authenticated;
