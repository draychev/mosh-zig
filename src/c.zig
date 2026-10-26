pub const c = @cImport({
    // glibc fortified inline aliases are not linkable from translate-c output.
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cDefine("_XOPEN_SOURCE", "700");
    @cDefine("_DEFAULT_SOURCE", "1");
    @cInclude("unistd.h");
    @cInclude("errno.h");
    @cInclude("stdlib.h");
    @cInclude("locale.h");
    @cInclude("wchar.h");
    @cInclude("termios.h");
    @cInclude("signal.h");
    @cInclude("poll.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/resource.h");
    @cInclude("netdb.h");
    @cInclude("time.h");
    @cInclude("openssl/evp.h");
    @cInclude("zlib.h");
});
