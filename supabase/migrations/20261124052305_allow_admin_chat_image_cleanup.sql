grant execute on function private.is_app_admin(uuid) to authenticated;
drop policy if exists chat_images_delete_admin on storage.objects;
create policy chat_images_delete_admin on storage.objects
for delete to authenticated
using (bucket_id = 'chat-images' and private.is_app_admin((select auth.uid())));
