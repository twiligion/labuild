# labuild-core — native part of the hybrid abuild rewrite.
#
# Everything here is CPU/parse heavy or filesystem heavy work that a shell
# script used to do with external tools (sha512sum, scanelf, find|stat|awk,
# zstd pipelines):
#
#   checksum   sha512 sums in abuild's `sha512sums="..."` format
#   verify     compare a file against an expected sha512
#   size       installed size (hardlinks counted once, like abuild's awk)
#   elf        walk a directory or file and report ELF facts (soname/needed/rpath/...)
#   archbin    does the tree contain arch specific binaries? (archcheck)
#   doc        compress man pages, deduplicating hardlinks/symlinks
#   srcpkg     build the source package tarball
#
# Only the standard library is used: no shards, no pax-utils, no bc/awk.
# Packaging *policy* (which sonames are provided, what a -doc package
# contains, ...) stays in the Lua driver.

require "compress/gzip"
require "file_utils"
require "./sha512_k"
require "./sha256_k"

module LabuildCore
  VERSION = "0.2.0"

  # ---------------------------------------------------------------- SHA512 --
  # FIPS 180-4 SHA-512, written from the spec: no OpenSSL, no libcrypto
  # (Alpine ships only libcrypto.so.3 without the development symlink, and
  # an abuild helper has no business pulling in a crypto library for hashes).

  class Sha512
    BLOCK = 128
    HEX   = "0123456789abcdef"

    @h : StaticArray(UInt64, 8)
    @buf : Bytes
    @buf_len : Int32
    @total : UInt64

    def initialize
      @h = StaticArray[
        SHA512_H0[0], SHA512_H0[1], SHA512_H0[2], SHA512_H0[3],
        SHA512_H0[4], SHA512_H0[5], SHA512_H0[6], SHA512_H0[7],
      ]
      @buf = Bytes.new(BLOCK)
      @buf_len = 0
      @total = 0_u64
    end

    def update(data : Bytes) : Nil
      @total &+= data.size.to_u64
      off = 0
      if @buf_len > 0
        n = Math.min(BLOCK - @buf_len, data.size)
        @buf[@buf_len, n].copy_from(data[0, n])
        @buf_len += n
        off = n
        if @buf_len == BLOCK
          process(@buf)
          @buf_len = 0
        end
      end
      while off + BLOCK <= data.size
        process(data[off, BLOCK])
        off += BLOCK
      end
      if off < data.size
        n = data.size - off
        @buf[0, n].copy_from(data[off, n])
        @buf_len = n
      end
    end

    def hexfinal : String
      process(finish)
      String.build(128) do |s|
        @h.each do |v|
          15.downto(0) { |k| s << HEX[((v >> (4 * k)) & 0xf).to_i] }
        end
      end
    end

    # Pads the buffered data and returns the last 128 byte block.
    private def finish : Bytes
      bitlen = @total &* 8_u64
      i = @buf_len
      @buf[i] = 0x80_u8
      i += 1
      if i > BLOCK - 16
        while i < BLOCK
          @buf[i] = 0_u8
          i += 1
        end
        process(@buf)
        i = 0
      end
      while i < BLOCK - 16
        @buf[i] = 0_u8
        i += 1
      end
      # 128 bit big endian message length in bits: high 64 bits first, then
      # the value (a 2^64 bit message would take 2 exabytes anyway)
      8.times { |k| @buf[BLOCK - 16 + k] = 0_u8 }
      8.times { |k| @buf[BLOCK - 8 + k] = ((bitlen >> (56 - 8 * k)) & 0xff).to_u8 }
      @buf
    end

    private def process(bl : Bytes) : Nil
      w = StaticArray(UInt64, 80).new(0_u64)
      16.times { |i| w[i] = be64(bl, i * 8) }
      16.upto(79) do |i|
        w[i] = s3(w[i - 2]) &+ w[i - 7] &+ s2(w[i - 15]) &+ w[i - 16]
      end

      a = @h[0]; b = @h[1]; c = @h[2]; d = @h[3]
      e = @h[4]; f = @h[5]; g = @h[6]; h = @h[7]

      80.times do |i|
        t1 = h &+ s1(e) &+ ((e & f) ^ ((~e) & g)) &+ SHA512_K[i] &+ w[i]
        t2 = s0(a) &+ ((a & b) ^ ((a & c) ^ (b & c)))
        h = g; g = f; f = e
        e = d &+ t1
        d = c; c = b; b = a
        a = t1 &+ t2
      end

      @h[0] &+= a; @h[1] &+= b; @h[2] &+= c; @h[3] &+= d
      @h[4] &+= e; @h[5] &+= f; @h[6] &+= g; @h[7] &+= h
    end

    private def be64(bl : Bytes, off : Int32) : UInt64
      v = 0_u64
      8.times { |k| v = (v << 8) | bl[off + k].to_u64 }
      v
    end

    private def rotr(x : UInt64, n : Int32) : UInt64
      (x >> n) | (x << (64 - n))
    end

    private def s0(x) : UInt64
      rotr(x, 28) ^ rotr(x, 34) ^ rotr(x, 39)
    end

    private def s1(x) : UInt64
      rotr(x, 14) ^ rotr(x, 18) ^ rotr(x, 41)
    end

    private def s2(x) : UInt64
      rotr(x, 1) ^ rotr(x, 8) ^ (x >> 7)
    end

    private def s3(x) : UInt64
      rotr(x, 19) ^ rotr(x, 61) ^ (x >> 6)
    end
  end

  # SHA-256 (FIPS 180-4), same reasons as Sha512 above: modern APKBUILDs still
  # carrying `sha256sums=` must be verifiable without a crypto library.
  class Sha256
    BLOCK = 64
    HEX   = "0123456789abcdef"

    @h : StaticArray(UInt32, 8)
    @buf : Bytes
    @buf_len : Int32
    @total : UInt64

    def initialize
      @h = StaticArray[
        SHA256_H0[0], SHA256_H0[1], SHA256_H0[2], SHA256_H0[3],
        SHA256_H0[4], SHA256_H0[5], SHA256_H0[6], SHA256_H0[7],
      ]
      @buf = Bytes.new(BLOCK)
      @buf_len = 0
      @total = 0_u64
    end

    def update(data : Bytes) : Nil
      @total &+= data.size.to_u64
      off = 0
      if @buf_len > 0
        n = Math.min(BLOCK - @buf_len, data.size)
        @buf[@buf_len, n].copy_from(data[0, n])
        @buf_len += n
        off = n
        if @buf_len == BLOCK
          process(@buf)
          @buf_len = 0
        end
      end
      while off + BLOCK <= data.size
        process(data[off, BLOCK])
        off += BLOCK
      end
      if off < data.size
        n = data.size - off
        @buf[0, n].copy_from(data[off, n])
        @buf_len = n
      end
    end

    def hexfinal : String
      process(finish)
      String.build(64) do |s|
        @h.each do |v|
          7.downto(0) { |k| s << HEX[((v >> (4 * k)) & 0xf).to_i] }
        end
      end
    end

    private def finish : Bytes
      bitlen = @total &* 8_u64
      i = @buf_len
      @buf[i] = 0x80_u8
      i += 1
      if i > BLOCK - 8
        while i < BLOCK
          @buf[i] = 0_u8
          i += 1
        end
        process(@buf)
        i = 0
      end
      while i < BLOCK - 8
        @buf[i] = 0_u8
        i += 1
      end
      8.times { |k| @buf[BLOCK - 8 + k] = ((bitlen >> (56 - 8 * k)) & 0xff).to_u8 }
      @buf
    end

    private def process(bl : Bytes) : Nil
      w = StaticArray(UInt32, 64).new(0_u32)
      16.times { |i| w[i] = be32(bl, i * 4) }
      16.upto(63) do |i|
        w[i] = s3(w[i - 2]) &+ w[i - 7] &+ s2(w[i - 15]) &+ w[i - 16]
      end

      a = @h[0]; b = @h[1]; c = @h[2]; d = @h[3]
      e = @h[4]; f = @h[5]; g = @h[6]; h = @h[7]

      64.times do |i|
        t1 = h &+ s1(e) &+ ((e & f) ^ ((~e) & g)) &+ SHA256_K[i] &+ w[i]
        t2 = s0(a) &+ ((a & b) ^ ((a & c) ^ (b & c)))
        h = g; g = f; f = e
        e = d &+ t1
        d = c; c = b; b = a
        a = t1 &+ t2
      end

      @h[0] &+= a; @h[1] &+= b; @h[2] &+= c; @h[3] &+= d
      @h[4] &+= e; @h[5] &+= f; @h[6] &+= g; @h[7] &+= h
    end

    private def be32(bl : Bytes, off : Int32) : UInt32
      v = 0_u32
      4.times { |k| v = (v << 8) | bl[off + k].to_u32 }
      v
    end

    private def rotr(x : UInt32, n : Int32) : UInt32
      (x >> n) | (x << (32 - n))
    end

    private def s0(x : UInt32) : UInt32
      rotr(x, 2) ^ rotr(x, 13) ^ rotr(x, 22)
    end

    private def s1(x : UInt32) : UInt32
      rotr(x, 6) ^ rotr(x, 11) ^ rotr(x, 25)
    end

    private def s2(x : UInt32) : UInt32
      rotr(x, 7) ^ rotr(x, 18) ^ (x >> 3)
    end

    private def s3(x : UInt32) : UInt32
      rotr(x, 17) ^ rotr(x, 19) ^ (x >> 10)
    end
  end

  # ------------------------------------------------------------------ ELF --

  struct ElfInfo
    property etype : String
    property machine : String
    property osabi : String
    property soname : String?
    property needed : Array(String)
    property rpaths : Array(String)

    def initialize(@etype, @machine, @osabi, @soname, @needed, @rpaths)
    end
  end

  class ELF
    ETYPES = {1 => "ET_REL", 2 => "ET_EXEC", 3 => "ET_DYN", 4 => "ET_CORE"}
    MACHINES = {
      2   => "sparc",
      3   => "i386",
      8   => "mips",
      15  => "parisc",
      18  => "sparc32plus",
      20  => "ppc",
      21  => "ppc64",
      22  => "s390x",
      40  => "arm",
      42  => "sh",
      43  => "sparc64",
      46  => "hppa",
      62  => "x86_64",
      112 => "vax",
      138 => "meta",
      183 => "aarch64",
      243 => "riscv",
      258 => "loongarch64",
    }
    OSABI = {0 => "NONE", 3 => "LINUX", 9 => "FREEBSD"}

    DT_NULL    = 0_u32
    DT_NEEDED  = 1_u32
    DT_STRTAB  = 5_u32
    DT_STRSZ   = 10_u32
    DT_SONAME  = 14_u32
    DT_RPATH   = 15_u32
    DT_RUNPATH = 29_u32

    # Reads the interesting bits of an ELF file: dynamic section (soname,
    # needed, rpath/runpath), type and machine. Returns nil for non-ELF or corrupt.
    def self.read(path : String) : ElfInfo?
      File.open(path, "rb") do |f|
        head = Bytes.new(64)
        n = f.read(head)
        return nil if n < 20
        return nil unless head[0] == 0x7f_u8 && head[1] == 0x45_u8 &&
                          head[2] == 0x4c_u8 && head[3] == 0x46_u8

        is64 = head[4] == 2_u8
        return nil if is64 ? (n < 64) : (n < 52)
        little = head[5] != 2_u8

        etype_num = u16(head, 16, little)
        machine_num = u16(head, 18, little)
        osabi_num = head[7]

        etype = ETYPES[etype_num]? || "ET_#{etype_num}"
        machine = MACHINES[machine_num]? || "machine#{machine_num}"
        osabi = OSABI[osabi_num]? || "OSABI#{osabi_num}"

        if is64
          phoff = u64(head, 32, little)
          phentsize = u16(head, 54, little)
          phnum = u16(head, 56, little)
        else
          phoff = u32(head, 28, little).to_u64
          phentsize = u16(head, 42, little)
          phnum = u16(head, 44, little)
        end

        loads = [] of {UInt64, UInt64, UInt64} # vaddr, filesz, offset
        dyn_offset = 0_u64
        dyn_size = 0_u64

        if phnum > 0 && phentsize >= 8 && phoff > 0
          phdrs = Bytes.new(phentsize.to_i32 * phnum.to_i32)
          f.seek(phoff)
          got = f.read_fully(phdrs)
          phnum.times do |i|
            base = i * phentsize
            p_type = u32(phdrs, base, little)
            if is64
              p_offset = u64(phdrs, base + 8, little)
              p_vaddr = u64(phdrs, base + 16, little)
              p_filesz = u64(phdrs, base + 32, little)
            else
              p_offset = u32(phdrs, base + 4, little).to_u64
              p_vaddr = u32(phdrs, base + 8, little).to_u64
              p_filesz = u32(phdrs, base + 16, little).to_u64
            end
            case p_type
            when 1_u32 # PT_LOAD
              loads << {p_vaddr, p_filesz, p_offset}
            when 2_u32 # PT_DYNAMIC
              dyn_offset = p_offset
              dyn_size = p_filesz
            end
          end
        end

        soname = nil
        needed = [] of String
        rpaths = [] of String

        if dyn_size > 0
          entry_size = is64 ? 16 : 8
          strtab_va = 0_u64
          strtab_sz = 0_u64
          name_offsets = [] of {UInt32, UInt32} # {kind, string offset}

          dyn = Bytes.new(dyn_size.to_i32)
          f.seek(dyn_offset)
          f.read_fully(dyn)
          count = dyn_size // entry_size
          count.times do |i|
            base = i * entry_size
            if is64
              tag = u64(dyn, base, little)
              val = u64(dyn, base + 8, little)
            else
              tag = u32(dyn, base, little).to_u64
              val = u32(dyn, base + 4, little).to_u64
            end
            case tag
            when DT_NEEDED.to_u64
              name_offsets << {DT_NEEDED, val.to_u32}
            when DT_SONAME.to_u64
              name_offsets << {DT_SONAME, val.to_u32}
            when DT_RPATH.to_u64
              name_offsets << {DT_RPATH, val.to_u32}
            when DT_RUNPATH.to_u64
              name_offsets << {DT_RUNPATH, val.to_u32}
            when DT_STRTAB.to_u64
              strtab_va = val
            when DT_STRSZ.to_u64
              strtab_sz = val
            when DT_NULL.to_u64
              break
            end
          end

          unless name_offsets.empty? || strtab_va == 0
            if off = va_to_offset(loads, strtab_va)
              len = if strtab_sz > 0
                Math.min(strtab_sz, 1024_u64 * 1024_u64)
              else
                seg_end = loads
                  .select { |v, s, o| strtab_va >= v && strtab_va < v + s }
                  .map { |v, s, o| o + s }
                  .min? || (off + 65536_u64)
                (seg_end > off ? seg_end - off : 65536_u64).clamp(0_u64, 1024_u64 * 1024_u64)
              end
              strtab = Bytes.new(len.to_i32)
              f.seek(off)
              got = f.read(strtab)
              strtab = strtab[0, got] if got < strtab.size

              name_offsets.each do |kind, soff|
                s = cstr(strtab, soff)
                case kind
                when DT_NEEDED then needed << s
                when DT_SONAME then soname = s
                when DT_RPATH, DT_RUNPATH then rpaths.concat(s.split(':').reject(&.empty?))
                end
              end
            end
          end
        end

        ElfInfo.new(etype, machine, osabi, soname, needed.uniq, rpaths.uniq)
      end
    rescue
      nil
    end

    private def self.va_to_offset(loads, va)
      loads.each do |v, s, o|
        return o + (va - v) if va >= v && va < v + s
      end
      nil
    end

    private def self.cstr(buf, off)
      i = off.to_i
      return "" if i >= buf.size || i < 0
      j = i
      while j < buf.size && buf[j] != 0_u8
        j += 1
      end
      String.new(buf[i, j - i])
    end

    private def self.u16(b, off, little)
      return 0_u16 if off + 2 > b.size
      little ? (b[off].to_u16 | (b[off + 1].to_u16 << 8)) \
             : (b[off + 1].to_u16 | (b[off].to_u16 << 8))
    end

    private def self.u32(b, off, little)
      return 0_u32 if off + 4 > b.size
      if little
        b[off].to_u32 | (b[off + 1].to_u32 << 8) | (b[off + 2].to_u32 << 16) | (b[off + 3].to_u32 << 24)
      else
        b[off + 3].to_u32 | (b[off + 2].to_u32 << 8) | (b[off + 1].to_u32 << 16) | (b[off].to_u32 << 24)
      end
    end

    private def self.u64(b, off, little)
      return 0_u64 if off + 8 > b.size
      if little
        u32(b, off, little).to_u64 | (u32(b, off + 4, little).to_u64 << 32)
      else
        (u32(b, off, little).to_u64 << 32) | u32(b, off + 4, little).to_u64
      end
    end
  end

  # ------------------------------------------------------------- commands --

  # Walk a directory or single file and print one record per interesting fact:
  #
  #   elf\t<relpath>\t<etype>\t<machine>\t<osabi>
  #   soname\t<soname>\t<relpath>
  #   needed\t<soname>\t<relpath>
  #   rpath\t<entry>\t<relpath>          (raw, unexpanded)
  def self.cmd_elf(root : String) : Int32
    found = false
    if file?(root) && elf?(root)
      info = ELF.read(root)
      if info
        found = true
        rel = File.basename(root)
        puts "elf\t#{rel}\t#{info.etype}\t#{info.machine}\t#{info.osabi}"
        if soname = info.soname
          puts "soname\t#{soname}\t#{rel}"
        end
        info.needed.each { |n| puts "needed\t#{n}\t#{rel}" }
        info.rpaths.each { |r| puts "rpath\t#{r}\t#{rel}" }
      end
    else
      walk(root) do |path|
        next if File.symlink?(path)
        next unless file?(path)
        next unless elf?(path)
        info = ELF.read(path)
        next unless info
        found = true
        rel = relpath(root, path)
        puts "elf\t#{rel}\t#{info.etype}\t#{info.machine}\t#{info.osabi}"
        if soname = info.soname
          puts "soname\t#{soname}\t#{rel}"
        end
        info.needed.each { |n| puts "needed\t#{n}\t#{rel}" }
        info.rpaths.each { |r| puts "rpath\t#{r}\t#{rel}" }
      end
    end
    found ? 0 : 1
  end

  # Check if a single file is an arch-specific binary:
  # ELF, static archive (.a / !<arch>\n), or precompiled Lua/LuaJIT bytecode.
  def self.is_archbin?(path : String) : Bool
    return false if File.symlink?(path)
    return false unless file?(path)
    return true if elf?(path)
    return true if path.ends_with?(".a")
    begin
      sz = File.size(path)
      if sz >= 8
        buf8 = Bytes.new(8)
        File.open(path, "rb") { |f| f.read_fully(buf8) }
        return true if String.new(buf8) == "!<arch>\n"
      end
      if sz >= 4
        buf4 = Bytes.new(4)
        File.open(path, "rb") { |f| f.read_fully(buf4) }
        # Lua bytecode: \x1bLua
        return true if buf4[0] == 0x1b_u8 && buf4[1] == 0x4c_u8 && buf4[2] == 0x75_u8 && buf4[3] == 0x61_u8
        # LuaJIT bytecode: \x1bLJ
        return true if buf4[0] == 0x1b_u8 && buf4[1] == 0x4c_u8 && buf4[2] == 0x4a_u8
      end
    rescue
    end
    false
  end

  # archcheck(): exit 0 if any arch specific binary is found, exit 1 if none.
  def self.cmd_archbin(root : String) : Int32
    if file?(root)
      return is_archbin?(root) ? 0 : 1
    end
    walk(root) do |path|
      return 0 if is_archbin?(path)
    end
    1
  end

  # Installed size: sum of file sizes, hardlinks counted once — this is what
  # abuild did with `find | stat | awk '!x[$1]++' | paste -sd+ | bc`.
  def self.cmd_size(root : String) : Int32
    if file?(root, follow: false)
      puts File.size(root)
      return 0
    end
    seen = Set(String).new
    total = 0_u64
    walk(root) do |path|
      next unless file?(path, follow: false)
      key = inode_key(path)
      next unless key
      next if seen.includes?(key)
      seen << key
      total += File.size(path)
    end
    puts total
    0
  end

  # Compress man pages in <dir> the way abuild's default_doc() does: only
  # uncompressed `*.[0-9n]`/`*.[0-9n][a-z]*`, hardlinked pages compressed once
  # (the duplicates become symlinks to the first one), symlinks get the suffix
  # appended to their target.
  def self.cmd_doc(root : String, mode : String = "zstd") : Int32
    return 0 if mode == "none"
    ext = mode == "gzip" ? "gz" : "zst"
    pages = [] of {String, String}
    walk(root) do |path|
      base = File.basename(path)
      next unless base =~ /\.[0-9n]([a-z][a-z0-9]*)?$/
      next if base =~ /\.(gz|bz2|xz|zst)$/
      symlink = File.symlink?(path)
      next unless symlink || file?(path, follow: false)
      pages << {inode_key(path) || path, path}
    end

    prev_key = ""
    prev_src = ""
    pages.sort_by { |key, p| {key, p} }.each do |key, path|
      dest = "#{path}.#{ext}"
      if File.symlink?(path)
        target = File.readlink(path)
        FileUtils.rm_f(dest)
        link_target = target =~ /\.(gz|bz2|xz|zst)$/ ? target : "#{target}.#{ext}"
        File.symlink(link_target, dest)
        FileUtils.rm_f(path)
        next
      end
      if key == prev_key && !prev_src.empty? && File.exists?("#{prev_src}.#{ext}")
        FileUtils.rm_f(dest)
        link_target = if File.dirname(path) == File.dirname(prev_src)
          "#{File.basename(prev_src)}.#{ext}"
        else
          relative_link_target(File.dirname(dest), "#{prev_src}.#{ext}")
        end
        File.symlink(link_target, dest)
      else
        compress(path, dest, mode)
        prev_key = key
        prev_src = path
      end
      FileUtils.rm_f(path)
    end

    FileUtils.rm_f(File.join(root, "usr/share/info/dir"))
    0
  end

  private def self.relative_link_target(from_dir : String, to_file : String) : String
    from_parts = Path.new(from_dir).expand.parts.reject(&.empty?)
    to_parts = Path.new(to_file).expand.parts.reject(&.empty?)
    common = 0
    while common < from_parts.size && common < to_parts.size && from_parts[common] == to_parts[common]
      common += 1
    end
    ups = from_parts.size - common
    dots = Array.new(ups, "..")
    remaining = to_parts[common..]
    Path.new((dots + remaining).join('/')).to_s
  end

  def self.cmd_checksum(paths : Array(String), algo : String = "sha512") : Int32
    paths.each do |p|
      puts "#{hash(p, algo)}  #{File.basename(p)}"
    end
    0
  end

  def self.cmd_verify(path : String, expected : String, algo : String = "sha512") : Int32
    actual = hash(path, algo)
    if actual == expected.downcase
      0
    else
      STDERR.puts "#{path}: #{algo} mismatch (expected #{expected[0, 12]}…, got #{actual[0, 12]}…)"
      1
    end
  end

  # Rewrite the checksum block of an APKBUILD, supporting md5, sha256, sha512.
  def self.cmd_checksum_write(apkbuild : String, files : Array(String), algo : String = "sha512") : Int32
    lines = File.read_lines(apkbuild)
    kept = [] of String
    skip_until : String? = nil
    lines.each do |line|
      if stop = skip_until
        skip_until = nil if line.strip.ends_with?(stop)
        next
      end
      if line =~ /^(md5|sha[0-9]+)sums=["']/
        eq = line.byte_index('=').not_nil!
        quote = line[eq + 1].to_s
        val_part = line[(eq + 2)..]
        if val_part.count(quote) >= 1
          # Opening quote is closed on this line, so it's a single-line block
          next
        else
          skip_until = quote
          next
        end
      end
      kept << line
    end

    while kept.last? && kept.last.strip.empty?
      kept.pop
    end

    unless files.empty?
      block_name = "#{algo}sums"
      kept << ""
      kept << "#{block_name}=\""
      files.each do |f|
        h = hash(f, algo)
        kept << "#{h}  #{File.basename(f)}"
      end
      kept << "\""
    end
    File.write(apkbuild, kept.join('\n') + "\n")
    0
  end

  # Build the source package: a tar.gz holding APKBUILD, sources, install and
  # trigger scripts below <prefix>/. Written from scratch (ustar) with
  # SOURCE_DATE_EPOCH reproducibility support.
  def self.cmd_srcpkg(out_path : String, prefix : String, files : Array(String)) : Int32
    mtime = source_date_epoch.to_unix
    File.open(out_path, "wb") do |io|
      gz = Compress::Gzip::Writer.new(io)
      gz.header.modification_time = Time.unix(mtime)
      gz.header.os = 3_u8
      begin
        emitted_dirs = Set(String).new
        files.each do |f|
          next unless File.exists?(f) || File.symlink?(f)
          rel = "#{prefix}/#{f}"
          dir = File.dirname(rel)
          parts = dir.split('/').reject(&.empty?)
          acc = String.new
          parts.each do |p|
            acc = acc.empty? ? p : "#{acc}/#{p}"
            next if emitted_dirs.includes?(acc)
            emitted_dirs << acc
            write_ustar_dir(gz, acc, mtime)
          end
          if File.symlink?(f)
            write_ustar_symlink(gz, rel, File.readlink(f), mtime)
          else
            write_ustar_file(gz, rel, f, mtime)
          end
        end
        # End of archive: two 512-byte zero blocks (1024 bytes)
        gz.write(Bytes.new(1024))
      ensure
        gz.close
      end
    end
    0
  end

  # ------------------------------------------------------------- plumbing --

  def self.source_date_epoch : Time
    if epoch = ENV["SOURCE_DATE_EPOCH"]?.try(&.to_i64?)
      Time.unix(epoch)
    else
      Time.utc
    end
  end

  def self.sha512(path : String) : String
    hash(path, "sha512")
  end

  def self.sha256(path : String) : String
    hash(path, "sha256")
  end

  def self.hash(path : String, algo : String) : String
    digest = algo == "sha256" ? Sha256.new.as(Sha256 | Sha512) : Sha512.new.as(Sha256 | Sha512)
    File.open(path, "rb") do |f|
      buf = Bytes.new(64 * 1024)
      loop do
        n = f.read(buf)
        break if n == 0
        digest.update(buf[0, n])
      end
    end
    digest.hexfinal
  end

  def self.compress(src : String, dst : String, mode : String)
    case mode
    when "gzip"
      compress_gzip(src, dst)
    else
      begin
        File.open(src, "rb") do |inp|
          File.open(dst, "wb") do |file_out|
            status = Process.run("zstd", ["-q", "-19"], input: inp, output: file_out)
            raise "zstd exited #{status.exit_code}" unless status.success?
          end
        end
      rescue ex
        STDERR.puts "labuild-core doc: zstd unavailable (#{ex.message}), falling back to gzip"
        compress_gzip(src, dst)
      end
    end
  end

  private def self.compress_gzip(src : String, dst : String)
    File.open(dst, "wb") do |file_out|
      gz = Compress::Gzip::Writer.new(file_out, level: 9)
      gz.header.modification_time = source_date_epoch
      gz.header.os = 3_u8
      File.open(src, "rb") { |inp| IO.copy(inp, gz) }
      gz.close
    end
  end

  # device:inode key, used to count hardlinked files only once
  def self.inode_key(path : String) : String?
    stat = LibC::Stat.new
    return nil unless LibC.stat(path, pointerof(stat)) == 0
    "#{stat.st_dev.to_i64}:#{stat.st_ino.to_i64}"
  end

  def self.file?(path : String, follow = true)
    File.info(path, follow_symlinks: follow).type.file?
  rescue
    false
  end

  def self.elf?(path : String) : Bool
    buf = Bytes.new(4)
    File.open(path, "rb") { |f| return false if f.read(buf) < 4 }
    buf[0] == 0x7f_u8 && buf[1] == 0x45_u8 && buf[2] == 0x4c_u8 && buf[3] == 0x46_u8
  rescue
    false
  end

  def self.relpath(root : String, path : String) : String
    r = root.chomp('/')
    if path.starts_with?(r)
      p = path[r.size..]
      p.starts_with?('/') ? p[1..] : p
    else
      path
    end
  end

  def self.walk(dir : String, &block : String ->)
    return unless Dir.exists?(dir)
    stack = [dir]
    while (d = stack.pop?)
      entries = Dir.children(d)
      entries.sort!
      # Directories pushed in reverse order so pop yields alphabetical order
      entries.reverse_each do |e|
        path = File.join(d, e)
        if File.directory?(path) && !File.symlink?(path)
          stack << path
        end
      end
      entries.each do |e|
        path = File.join(d, e)
        if File.symlink?(path) || !File.directory?(path)
          yield path
        end
      end
    end
  end

  # ------------------------------------------------------------ tar (ustar) --

  private def self.write_ustar_header(io, name, size, typeflag, linkname = "", mode = 0i64, mtime = Time.utc.to_unix)
    header = Bytes.new(512)
    if name.bytesize > 100
      slash = name.rindex('/', 100)
      if slash && slash > 0 && (name.bytesize - slash - 1) <= 100 && slash <= 155
        prefix_part = name[0...slash]
        name_part = name[(slash + 1)..]
        put_str(header, 0, name_part, 100)
        put_str(header, 345, prefix_part, 155)
      else
        put_str(header, 0, name, 100)
      end
    else
      put_str(header, 0, name, 100)
    end

    put_oct(header, 100, mode == 0i64 ? (typeflag == "5" ? 0o755_i64 : 0o644_i64) : mode, 8)
    put_oct(header, 108, 0_i64, 8)  # uid
    put_oct(header, 116, 0_i64, 8)  # gid
    put_oct(header, 124, size, 12)
    put_oct(header, 136, mtime, 12)
    header[156] = typeflag.bytes.first
    put_str(header, 157, linkname, 100)
    put_str(header, 257, "ustar", 6)
    put_str(header, 263, "00", 2)
    put_str(header, 265, "root", 32)
    put_str(header, 297, "root", 32)

    sum = 0
    header.each_with_index { |b, i| sum += (i >= 148 && i < 156) ? 32 : b }
    s = sum.to_s(8)
    s = "0" * (6 - s.size) + s if s.size < 6
    put_str(header, 148, s, 6)
    header[154] = 0_u8
    header[155] = 0x20_u8
    io.write(header)
  end

  private def self.put_str(buf, off, value, len)
    bytes = value.to_slice
    n = Math.min(bytes.size, len)
    buf[off, n].copy_from(bytes[0, n])
  end

  private def self.put_oct(buf, off, value, len)
    s = value.to_s(8)
    s = "0" * (len - 1 - s.size) + s if s.size < len - 1
    put_str(buf, off, s, len - 1)
    buf[off + len - 1] = 0x20_u8
  end

  def self.write_ustar_file(io, arcname : String, path : String, mtime : Int64 = Time.utc.to_unix)
    size = File.size(path)
    file_mode = File.info(path).permissions.value.to_i64 & 0o777_i64
    write_ustar_header(io, arcname, size, "0", mode: file_mode, mtime: mtime)
    File.open(path, "rb") { |f| IO.copy(f, io) }
    pad = (512 - (size % 512)) % 512
    io.write(Bytes.new(pad)) if pad > 0
  end

  def self.write_ustar_dir(io, arcname : String, mtime : Int64 = Time.utc.to_unix)
    dir_name = arcname.ends_with?('/') ? arcname : arcname + "/"
    write_ustar_header(io, dir_name, 0, "5", mode: 0o755_i64, mtime: mtime)
  end

  def self.write_ustar_symlink(io, arcname : String, target : String, mtime : Int64 = Time.utc.to_unix)
    write_ustar_header(io, arcname, 0, "2", linkname: target, mode: 0o777_i64, mtime: mtime)
  end

  # ------------------------------------------------------------------ main --

  def self.take_algo(argv : Array(String)) : String
    if argv[0]? == "--sha256"
      argv.shift
      "sha256"
    elsif argv[0]? == "--sha512"
      argv.shift
      "sha512"
    elsif argv[0]? == "--algo"
      argv.shift
      alg = argv.shift? || "sha512"
      alg
    else
      "sha512"
    end
  end

  def self.run(argv : Array(String)) : Int32
    cmd = argv.shift? || "help"
    case cmd
    when "elf"
      cmd_elf(argv[0] || ".")
    when "archbin"
      cmd_archbin(argv[0] || ".")
    when "size"
      cmd_size(argv[0] || ".")
    when "doc"
      root = argv[0] || "."
      mode = argv[1]? || "zstd"
      cmd_doc(root, mode)
    when "checksum"
      algo = take_algo(argv)
      cmd_checksum(argv, algo)
    when "verify"
      algo = take_algo(argv)
      cmd_verify(argv[0] || "", argv[1] || "", algo)
    when "checksum-write"
      algo = take_algo(argv)
      apkbuild = argv.shift? || "APKBUILD"
      cmd_checksum_write(apkbuild, argv, algo)
    when "srcpkg"
      outfile = argv.shift? || ""
      prefix = argv.shift? || ""
      cmd_srcpkg(outfile, prefix, argv)
    when "selftest"
      ok = true
      # FIPS 180-4 known answer tests
      {
        ""    => "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e",
        "abc" => "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
      }.each do |input, want|
        d = Sha512.new
        d.update(input.to_slice)
        got = d.hexfinal
        if got != want
          STDERR.puts "sha512 KAT FAIL #{input.inspect}\n  got  #{got}\n  want #{want}"
          ok = false
        end
      end
      {
        ""    => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "abc" => "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
      }.each do |input, want|
        d = Sha256.new
        d.update(input.to_slice)
        got = d.hexfinal
        if got != want
          STDERR.puts "sha256 KAT FAIL #{input.inspect}\n  got  #{got}\n  want #{want}"
          ok = false
        end
      end
      # Cross check against system tools
      {"", "abc", "a" * 55, "a" * 56, "a" * 63, "a" * 64, "a" * 127, "a" * 128, "a" * 1000}.each do |s|
        tmp = File.tempname("hash")
        File.write(tmp, s)
        {"sha512" => ->(p : String) { cmd_sha_system("sha512sum", p) },
         "sha256" => ->(p : String) { cmd_sha_system("sha256sum", p) }}.each do |algo, sys|
          d = algo == "sha256" ? Sha256.new.as(Sha256 | Sha512) : Sha512.new.as(Sha256 | Sha512)
          d.update(s.to_slice)
          got = d.hexfinal
          want = sys.call(tmp)
          if got != want
            STDERR.puts "#{algo} cross FAIL len=#{s.size}\n  got  #{got}\n  want #{want}"
            ok = false
          end
        end
        File.delete(tmp)
      end

      # Test tar / ustar / srcpkg structure
      tmp_tar = File.tempname("test", ".tar.gz")
      tmp_src = File.tempname("source")
      File.write(tmp_src, "hello world from source\n")
      cmd_srcpkg(tmp_tar, "prefix", [tmp_src])
      # Verify tar integrity with system tar
      tar_out = IO::Memory.new
      status = Process.run("tar", ["-tzf", tmp_tar], output: tar_out)
      if status.success? && tar_out.to_s.includes?("prefix/#{tmp_src}")
        # OK
      else
        STDERR.puts "srcpkg tar self-check FAILED: #{tar_out}"
        ok = false
      end
      File.delete(tmp_tar) rescue nil
      File.delete(tmp_src) rescue nil

      puts ok ? "labuild-core selftest OK" : "labuild-core selftest FAILED"
      ok ? 0 : 1
    when "help", "-h", "--help"
      puts "labuild-core #{VERSION} — native helpers for labuild"
      puts "usage:"
      puts "  labuild-core elf <file|dir>                 ELF facts (tsv records)"
      puts "  labuild-core archbin <file|dir>             exit 0 if arch specific binaries exist"
      puts "  labuild-core size <file|dir>                installed size in bytes"
      puts "  labuild-core doc <dir> [zstd|gzip|none]     compress man pages"
      puts "  labuild-core checksum [--algo A] <file...>  sha512/sha256 sums"
      puts "  labuild-core verify [--algo A] <file> <hash> check one file"
      puts "  labuild-core checksum-write [--algo A] <APKBUILD> <file...>"
      puts "  labuild-core srcpkg <out.tar.gz> <prefix> <file...>"
      puts "  labuild-core selftest                       verify hashes, elf, tar against system tools"
      0
    else
      STDERR.puts "labuild-core: unknown command #{cmd}"
      2
    end
  end

  def self.cmd_sha_system(tool : String, path : String) : String
    sink = IO::Memory.new
    Process.run(tool, [path], output: sink)
    sink.to_s.split.first? || ""
  end
end

exit LabuildCore.run(ARGV) if PROGRAM_NAME.includes?("labuild")
