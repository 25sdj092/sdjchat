CREATE OR REPLACE FUNCTION public.mark_room_images_deleted(p_conv uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_changed integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING errcode = '28000';
  END IF;

  UPDATE public.messages AS msg
  SET message_type = 'text',
      content = '사진이 삭제되었습니다.',
      storage_path = NULL,
      mime_type = NULL,
      file_size = NULL
  FROM public.conversations AS conv
  WHERE msg.conversation_id = p_conv
    AND msg.message_type = 'image'
    AND conv.id = msg.conversation_id
    AND conv.type IN ('open', 'group')
    AND conv.owner_id = v_uid
    AND EXISTS (
      SELECT 1
      FROM public.conversation_members AS member
      WHERE member.conversation_id = conv.id
        AND member.user_id = v_uid
        AND member.left_at IS NULL
    );

  GET DIAGNOSTICS v_changed = ROW_COUNT;
  RETURN v_changed;
END;
$function$;

REVOKE ALL ON FUNCTION public.mark_room_images_deleted(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_room_images_deleted(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.mark_room_images_deleted(uuid) TO authenticated;
