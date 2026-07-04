# Jumper commissioner: the game-agnostic default commissioner with the
# Jumper ruleset config baked in and selected.
FROM ghcr.io/metta-ai/commissioners-default@sha256:75d77cf97479317c88988104b553ce746718138608ea00fcc14398d95e8d9b8f

COPY commissioner/jumper.yaml /app/commissioners/ruleset_strategy_commissioner/configs/jumper.yaml
ENV RULESET_STRATEGY_CONFIG_NAME=jumper
