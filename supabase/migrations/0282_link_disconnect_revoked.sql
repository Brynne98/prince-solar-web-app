-- SOLAR-681 R24 (Review L item 1): api_link_disconnect was still callable by signed-in users
-- (granted in 0102). Called directly it deleted the login row and skipped billing.remove_login,
-- leaving billing.logins and its seats behind. Its only caller is api_link_remove, which runs as
-- its owner, so the grant goes; the function itself goes when api_link_remove stops calling it.
revoke execute on function public.api_link_disconnect(uuid) from public, anon, authenticated;
