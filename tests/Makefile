CC ?= clang
CFLAGS ?= -Wall -Wextra -Werror -O2 -std=c11
FRAMEWORKS = -framework CoreGraphics -framework CoreFoundation

TARGET = test_ipc

all: $(TARGET)

$(TARGET): test_ipc.c ../native/shared/protocol.h
	$(CC) $(CFLAGS) $(FRAMEWORKS) -o $@ test_ipc.c

clean:
	[ ! -f $(TARGET) ] || rm $(TARGET)

.PHONY: all clean
