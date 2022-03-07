defmodule UdpThing do

  # nc -6 -u ff12::1%en3 1

  @ip6_protocol [macos: -1, bsd: -1, linux: 41]
  @ip6_add_membership [macos: 12, bsd: 12, linux: 20]
  @ip6_drop_membership [macos: 13, bsd: 13, linux: 21]

  def ipv6_to_binary(ipv6addressstr) when is_binary(ipv6addressstr) do
    {:ok, {n1,n2,n3,n4,n5,n6,n7,n8}} = :inet_parse.ipv6strict_address(ipv6addressstr |> :erlang.binary_to_list)
    <<n1::16, n2::16, n3::16, n4::16, n5::16, n6::16, n7::16, n8::16>>
  end

  @maddr <<65298::16, 0::16, 0::16, 0::16, 0::16, 0::16, 0::16, 1::16>>

  def run(os \\ :linux, eth \\ "eth0") do
    port = 1
    maddr = ipv6_to_binary("ff12::1")
    IO.inspect maddr, label: :MADDR
    {:ok, ifindx} = :net.if_name2index(eth |> :erlang.binary_to_list)
    IO.inspect eth, label: :ETH
    IO.inspect ifindx, label: :IFINDX
    ip6 = @ip6_protocol[os]
    ip6am = @ip6_add_membership[os]
    raw = {:raw, ip6, ip6am, <<maddr::binary, ifindx::little-integer-32>>}
    IO.inspect raw, label: :IP_RAW

    {:ok, sock} = :gen_udp.open(port, [{:reuseaddr,true}, :inet6, :binary, raw])
    :io.format("raw: ~w ~n", [raw])

    loop()
  end

  def loop() do
    receive do
      msg ->
        :io.format("got: ~w ~n", [msg])
    end
    loop()
  end
end

UdpThing.run(:linux, "enp8s0u1u4u1")
# UdpThing.run(:macos, "en0")
