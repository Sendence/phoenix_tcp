Code.require_file "../../support/ranch_tcp_client.exs", __DIR__

defmodule PhoenixTCP.Integration.RanchTCPTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias PhoenixTCP.RanchTCPClient
  alias Phoenix.Socket.Message
  alias __MODULE__.Endpoint

  @port 5801

  Application.put_env(:phoenix, Endpoint, [
    tcp_handler: PhoenixTCP.RanchHandler,
    tcp: [port: @port],
    pubsub: [adapter: Phoenix.PubSub.PG2, name: __MODULE__]
  ])

  defmodule RoomChannel do
    use Phoenix.Channel

    intercept ["new_msg"]

    def join(topic, message, socket) do
      Process.register(self, String.to_atom(topic))
      send(self, {:after_join, message})
      {:ok, socket}
    end

    def handle_info({:after_join, message}, socket) do
      broadcast socket, "user_entered", %{user: message["user"]}
      push socket, "joined", Map.merge(%{status: "connected"}, socket.assigns)
      {:noreply, socket}
    end

    def handle_in("new_msg", message, socket) do
      broadcast! socket, "new_msg", message
      {:noreply, socket}
    end

    def handle_in("boom", _message, _socket) do
      raise "boom"
    end

    def handle_out("new_msg", payload, socket) do
      push socket, "new_msg", Map.put(payload, "transport", inspect(socket.transport))
      {:noreply, socket}
    end

    def terminate(_reason, socket) do
      push socket, "you_left", %{message: "bye!"}
      :ok
    end
  end

  defmodule UserSocket do
    use Phoenix.Socket

    channel "rooms:*", RoomChannel

    transport :tcp, PhoenixTCP.Transports.TCP

    def connect(%{"reject" => "true"}, _socket) do
      :error
    end

    def connect(params, socket) do
      Logger.disable(self())
      {:ok, assign(socket, :user_id, params["user_id"])}
    end

    def id(socket) do
      if id = socket.assigns.user_id, do: "user_sockets:#{id}"
    end
  end

  defmodule LoggingSocket do
    use Phoenix.Socket

    channel "rooms:*", RoomChannel

    transport :tcp, PhoenixTCP.Transports.TCP

    def connect(%{"reject" => "true"}, _socket) do
      :error
    end

    def connect(params, socket) do
      {:ok, assign(socket, :user_id, params["user_id"])}
    end

    def id(socket) do
      if id = socket.assigns.user_id, do: "user_sockets:#{id}"
    end
  end

  defmodule Endpoint do
    use Phoenix.Endpoint, otp_app: :phoenix

    socket "/tcp", UserSocket
    socket "/tcp/admin", UserSocket
    socket "/tcp/logging", LoggingSocket
  end

  setup_all do
    capture_log fn -> Endpoint.start_link() end
    capture_log fn -> PhoenixTCP.Supervisor.start_link(:phoenix, Endpoint) end
    :ok
  end

  test "endpoint handles multiple mount segments" do
    {:ok, sock} = RanchTCPClient.start_link(self, "localhost", @port, "/tcp/admin/tcp")
    RanchTCPClient.join(sock, "rooms:admin-lobby", %{})
    assert_receive %Message{event: "phx_reply",
                            payload: %{"response" => %{}, "status" => "ok"},
                            ref: "1", topic: "rooms:admin-lobby"}
  end

  test "join, leave, and event messages" do
    {:ok, sock} = RanchTCPClient.start_link(self, "localhost", @port, "/tcp/tcp")
    RanchTCPClient.join(sock, "rooms:lobby1", %{})

    assert_receive %Message{event: "phx_reply",
                            payload: %{"response" => %{}, "status" => "ok"},
                            ref: "1", topic: "rooms:lobby1"}
    assert_receive %Message{event: "joined", payload: %{"status" => "connected",
                                                        "user_id" => nil}}
    assert_receive %Message{event: "user_entered",
                            payload: %{"user" => nil},
                            ref: nil, topic: "rooms:lobby1"}

    channel_pid = Process.whereis(:"rooms:lobby1")
    assert channel_pid
    assert Process.alive?(channel_pid)

    RanchTCPClient.send_event(sock, "rooms:lobby1", "new_msg", %{body: "hi!"})
    assert_receive %{event: "new_msg", payload: %{"transport" => "PhoenixTCP.Transports.TCP", "body" => "hi!"}}

    RanchTCPClient.leave(sock, "rooms:lobby1", %{})
    assert_receive %Message{event: "you_left", payload: %{"message" => "bye!"}}
    assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}
    assert_receive %Message{event: "phx_close", payload: %{}}
    refute Process.alive?(channel_pid)

    RanchTCPClient.send_event(sock, "rooms:lobby1", "new_msg", %{body: "Should ignore"})
    refute_receive %Message{event: "new_msg"}
    assert_receive %Message{event: "phx_reply", payload: %{"response" => %{"reason" => "unmatched topic"}}}

    RanchTCPClient.send_event(sock, "rooms:lobby1", "new_msg", %{body: "Should ignore"})
    refute_receive %Message{event: "new_msg"}
  end

  test "filter params on join" do
    {:ok, sock} = RanchTCPClient.start_link(self, "localhost", @port, "/tcp/logging/tcp")
    log = capture_log fn ->
      RanchTCPClient.join(sock, "rooms:admin-lobby", %{"foo" => "bar", "password" => "shouldnotshow"})
      assert_receive %Message{event: "phx_reply",
                              payload: %{"response" => %{}, "status" => "ok"},
                              ref: "1", topic: "rooms:admin-lobby"}
    end
    assert log =~ "JOIN rooms:admin-lobby to PhoenixTCP.Integration.RanchTCPTest.RoomChannel\n  Transport:  PhoenixTCP.Transports.TCP\n  Parameters: %{\"foo\" => \"bar\", \"password\" => \"shouldnotshow\"}Replied rooms:admin-lobby :ok"
  end

  test "sends phx_error if a channel server abnormally exits" do
    {:ok, sock} = RanchTCPClient.start_link(self, "localhost", @port, "/tcp/tcp")

    RanchTCPClient.join(sock, "rooms:lobby", %{})
    assert_receive %Message{event: "phx_reply", ref: "1", payload: %{"response" => %{}, "status" => "ok"}}
    assert_receive %Message{event: "joined"}
    assert_receive %Message{event: "user_entered"}

    capture_log fn ->
      RanchTCPClient.send_event(sock, "rooms:lobby", "boom", %{})
      assert_receive %Message{event: "phx_error", payload: %{}, topic: "rooms:lobby"}
    end
  end

  test "channels are terminated if transport normally exits" do
    {:ok, sock} = RanchTCPClient.start_link(self, "localhost", @port, "/tcp/tcp")

    RanchTCPClient.join(sock, "rooms:lobby2", %{})
    assert_receive %Message{event: "phx_reply", ref: "1", payload: %{"response" => %{}, "status" => "ok"}}
    assert_receive %Message{event: "joined"}
    channel = Process.whereis(:"rooms:lobby2")
    assert channel
    Process.monitor(channel)
    RanchTCPClient.close(sock)
    assert_receive {:DOWN, _, :process, ^channel, {:shutdown, :closed}}
  end

  test "refuses websocket events that haven't joined" do
    {:ok, sock} = RanchTCPClient.start_link(self, "localhost", @port, "/tcp/tcp")

    RanchTCPClient.send_event(sock, "rooms:lobby", "new_msg", %{body: "hi!"})
    refute_receive %Message{event: "new_msg"}
    assert_receive %Message{event: "phx_reply", payload: %{"response" => %{"reason" => "unmatched topic"}}}

    RanchTCPClient.send_event(sock, "rooms:lobby1", "new_msg", %{body: "Should ignore"})
    refute_receive %Message{event: "new_msg"}
  end

  test "shuts down when receiving disconnect broadcasts on socket's id" do
    {:ok, sock} = RanchTCPClient.start_link(self, "localhost", @port, "/tcp/tcp", %{"user_id" => "1001"})

    RanchTCPClient.join(sock, "rooms:tcpdisconnect1", %{})
    assert_receive %Message{topic: "rooms:tcpdisconnect1", event: "phx_reply",
                            ref: "1", payload: %{"response" => %{}, "status" => "ok"}}
    RanchTCPClient.join(sock, "rooms:tcpdisconnect2", %{})
    assert_receive %Message{topic: "rooms:tcpdisconnect2", event: "phx_reply",
                            ref: "2", payload: %{"response" => %{}, "status" => "ok"}}

    chan1 = Process.whereis(:"rooms:tcpdisconnect1")
    assert chan1
    chan2 = Process.whereis(:"rooms:tcpdisconnect2")
    assert chan2
    Process.monitor(sock)
    Process.monitor(chan1)
    Process.monitor(chan2)
    Endpoint.broadcast("user_sockets:1001", "disconnect", %{})

    assert_receive {:DOWN, _, :process, ^sock, :normal}
    assert_receive {:DOWN, _, :process, ^chan1, {:shutdown, :closed}}
    assert_receive {:DOWN, _, :process, ^chan2, {:shutdown, :closed}}
  end

  test "duplicate join event logs and ignores messages" do
    {:ok, sock} = RanchTCPClient.start_link(self, "localhost", @port, "/tcp/tcp", %{"user_id" => "1001"})
    RanchTCPClient.join(sock, "rooms:joiner", %{})
    assert_receive %Message{topic: "rooms:joiner", event: "phx_reply",
                            ref: "1", payload: %{"response" => %{}, "status" => "ok"}}

    log = capture_log fn ->
      RanchTCPClient.join(sock, "rooms:joiner", %{})
      assert_receive %Message{topic: "rooms:joiner", event: "phx_reply",
                              payload: %{"response" => %{"reason" => "already joined"},
                                         "status" => "error"}}
    end
    assert log =~ "PhoenixTCP.Integration.RanchTCPTest.RoomChannel received join event with topic \"rooms:joiner\" but channel already joined"
  end

end
