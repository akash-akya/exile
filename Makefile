calling_from_make:
	mix compile

UNAME := $(shell uname)

CFLAGS ?= -Wall -Werror -Wno-unused-parameter -pedantic -std=c99 -O2

ifeq ($(UNAME), Darwin)
	TARGET_CFLAGS ?= -fPIC -undefined dynamic_lookup -dynamiclib -Wextra
endif

ifeq ($(UNAME), Linux)
	TARGET_CFLAGS ?= -fPIC -shared
endif


all: priv/exile.so

priv/exile.so: c_src/exile.c
	mkdir -p priv
	$(CC) -I$(ERL_INTERFACE_INCLUDE_DIR) $(TARGET_CFLAGS) $(CFLAGS) c_src/exile.c -o priv/exile.so

clean:
	@rm -rf priv/exile.so
