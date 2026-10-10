# Pin the existing size binding explicitly for Elixir 1.20; no algorithm change.
path = "deps/nimble_totp/lib/nimble_totp.ex"
source = File.read!(path)
original = "9618ad8ea186dbdcbbc9207cf5fa3e362128d1fc4090e37fb677e4eeaa700600"
digest = fn bytes -> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) end
old = "<<_::size(offset)-binary, p::4-binary, _::binary>> = hmac"
new = "<<_::size(^offset)-binary, p::4-binary, _::binary>> = hmac"

cond do
  digest.(source) == original ->
    File.write!(path, String.replace(source, old, new))

  digest.(String.replace(source, new, old)) == original and String.contains?(source, new) ->
    :ok

  true ->
    raise "NimbleTOTP source differs from reviewed 1.0.0"
end
