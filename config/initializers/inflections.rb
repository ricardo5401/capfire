# frozen_string_literal: true

# Acronym inflections are intentionally empty. The codebase uses the standard
# Rails camelize convention (`ApiToken`, `JwtService`, `SseWriter`) instead of
# the acronym-uppercase form (`APIToken`, `JWTService`, `SSEWriter`). Keeping
# this file here so future contributors know the choice was deliberate.
#
# If you ever decide to switch to acronym form, rename every affected class
# AND adapt every filename on the same commit — otherwise constant autoload
# breaks (e.g. `create_api_tokens.rb` would need to define `CreateAPITokens`).
