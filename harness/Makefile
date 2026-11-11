# =============================================================================
# Makefile — mdharness, the headless test runner
#
# libretro.h is vendored from libretro-common (MIT licensed, see its header).
# The core itself (Genesis Plus GX) is built separately; see the Dockerfile.
# =============================================================================

CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -std=c99 -D_POSIX_C_SOURCE=200809L
LDLIBS   = -lz -ldl

mdharness: mdharness.c libretro.h
	$(CC) $(CFLAGS) -o $@ mdharness.c $(LDLIBS)

.PHONY: clean
clean:
	rm -f mdharness
