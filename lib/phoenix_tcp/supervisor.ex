defmodule PhoenixTCP.Supervisor do
	# the supervisor for the underlying handlers
	@moduledoc false

	use Supervisor
	require Logger

	def start_link(otp_app, endpoint, opts \\ []) do
		Supervisor.start_link(__MODULE__, {otp_app, endpoint}, opts)
	end

	def init({otp_app, endpoint}) do
		children = []

		handler = endpoint.config(:tcp_handler)
		config =
		  if endpoint.config(:tcp) do
		    endpoint.config(:tcp)
		  else
		    default(Keyword.new(), otp_app, 5001)
		  end
		children = [handler.child_spec(:tcp, endpoint, config) | children]

		supervise(children, strategy: :one_for_one)
	end

	defp default(config, otp_app, port) do
		config =
			config
			|> Keyword.put_new(:otp_app, otp_app)
			|> Keyword.put_new(:port, port)

		Keyword.put(config, :port, to_port(config[:port]))
	end

	defp to_port(nil) do
		Logger.error "TCP Server will not start because :port in config is nil, please use a valid port number"
		exit(:shutdown)
	end
	defp to_port(binary)  when is_binary(binary),   do: String.to_integer(binary)
	defp to_port(integer) when is_integer(integer), do: integer
	defp to_port({:system, env_var}), do: to_port(System.get_env(env_var))
end
