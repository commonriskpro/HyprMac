CC = clang
CFLAGS = -arch arm64e -dynamiclib -framework CoreGraphics -undefined dynamic_lookup -O2
TARGET = libMenuBarInterposer.dylib
SRC = interposer.c

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(TARGET)

.PHONY: all clean
