import Config

# We are stuck with this until we can make Absinthe.Phoenix.Channel logging
# configurable from the outside.
config :logger, :level, :warning

config :phoenix, :json_library, Jason
