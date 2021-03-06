Mix.install [:msgpax]

defmodule UdpThing do

  # nc -6 -u ff12::1%en3 1

  @ip6_protocol [macos: -1, bsd: -1, linux: 41]
  @ip6_add_membership [macos: 12, bsd: 12, linux: 20]
  @ip6_drop_membership [macos: 13, bsd: 13, linux: 21]

  def ipv6_to_binary(ipv6addressstr) when is_binary(ipv6addressstr) do
    {:ok, {n1,n2,n3,n4,n5,n6,n7,n8}} =
      :inet_parse.ipv6strict_address(ipv6addressstr |> :erlang.binary_to_list)
    <<n1::16, n2::16, n3::16, n4::16, n5::16, n6::16, n7::16, n8::16>>
  end

  @maddr <<65298::16, 0::16, 0::16, 0::16, 0::16, 0::16, 0::16, 1::16>>

  def run(os \\ :linux, eth \\ "eth0", maddr \\ "ff12::1") do
    port = 2048
    maddr = ipv6_to_binary(maddr)
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
      pkt ->
        {:udp, _pid, ip6addr, _port, msg} = pkt
        try do
          msg! = msg |> Msgpax.unpack!()
          # :io.format("got msg: ~w ~n", [msg!])
          IO.inspect(msg!, label: :msg, width: 0)
          [10, _id, %{"linkLocal" => ipnums}] = msg!

          ipbs = ipnums |> :erlang.list_to_binary()
          ipgs = for <<group::16 <- ipbs >> do group end
          ip = ipgs |> List.to_tuple()
          ipstr = ip |> :inet.ntoa() |> to_string()

          # :io.format("IP: ~w ~n", [ipstr])

          # IO.inspect(msg!, label: :msg, width: 0)
          IO.inspect(ipstr, label: :IPSTR)
        rescue
          err ->
            # :io.format("got pkt: ~w ~n", [msg])
        end
        IO.puts ""
    end
    loop()
  end
end

ifidx =
  (System.get_env("IFIDX") || System.argv() |> Enum.at(0))
  |> IO.inspect(label: :IFIDX)

maddr =
  (System.get_env("MADDR") || System.argv() |> Enum.at(1) || "ff12::1")
  |> IO.inspect(label: :MADDR)

UdpThing.run(:linux, ifidx, maddr)
# UdpThing.run(:macos, "en0")
