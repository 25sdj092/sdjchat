DROP POLICY IF EXISTS messages_insert ON public.messages;
CREATE POLICY messages_insert
ON public.messages
FOR INSERT
TO authenticated
WITH CHECK (
  sender_id = (select auth.uid())
  AND private.is_active_member(conversation_id)
);

CREATE OR REPLACE FUNCTION public.send_friend_request(p_code text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  uid uuid := auth.uid();
  target uuid;
  f public.friendships;
  attempts integer;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode='28000';
  end if;
  if p_code is null or p_code !~ '^[0-9]{4}$' then
    raise exception 'invalid_code' using errcode='22023';
  end if;
  if not exists(select 1 from public.profiles where id=uid) then
    raise exception 'no_profile' using errcode='22023';
  end if;

  perform pg_advisory_xact_lock(hashtext(uid::text));
  delete from public.code_lookup_attempts
  where user_id=uid and attempted_at<now()-interval '1 hour';
  select count(*) into attempts
  from public.code_lookup_attempts
  where user_id=uid and attempted_at>now()-interval '10 minutes';
  if attempts>=10 then
    raise exception 'lookup_rate_limited' using errcode='P0001';
  end if;
  insert into public.code_lookup_attempts(user_id) values(uid);

  select id into target from public.profiles where user_code=p_code;
  if not found then
    raise exception 'user_not_found' using errcode='P0002';
  end if;
  if target=uid then
    raise exception 'self' using errcode='22023';
  end if;

  select * into f
  from public.friendships
  where least(requester_id,receiver_id)=least(uid,target)
    and greatest(requester_id,receiver_id)=greatest(uid,target);
  if found then
    if f.status='accepted' then return 'already_friends'; end if;
    if f.requester_id=uid then return 'already_sent'; end if;
    perform public._accept_friendship(f.id);
    return 'accepted';
  end if;
  insert into public.friendships(requester_id,receiver_id)
  values(uid,target) on conflict do nothing;
  return 'sent';
end;
$function$;

DROP FUNCTION IF EXISTS public.block_user(uuid, boolean);
DROP TABLE IF EXISTS public.user_blocks;
