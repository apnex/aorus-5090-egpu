savedcmd_aorus-egpu-trust.mod := printf '%s\n'   aorus-egpu-trust.o | awk '!x[$$0]++ { print("./"$$0) }' > aorus-egpu-trust.mod
