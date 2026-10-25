require "./labuild_core"

path = ARGV[0]? || "/usr/lib/libzstd.so.1"
head = Bytes.new(64)
f = File.open(path, "rb")
n = f.read(head)
puts "read=#{n} magic=#{head[0,4].to_a}"
def u16(b, off); b[off].to_u16 | (b[off+1].to_u16 << 8); end
def u32(b, off); b[off].to_u32 | (b[off+1].to_u32<<8) | (b[off+2].to_u32<<16) | (b[off+3].to_u32<<24); end
def u64(b, off); u32(b,off).to_u64 | (u32(b,off+4).to_u64 << 32); end
is64 = head[4] == 2
puts "is64=#{is64} etype=#{u16(head,16)} machine=#{u16(head,18)}"
phoff = is64 ? u64(head,32) : u32(head,28).to_u64
phentsize = u16(head, is64 ? 54 : 42)
phnum = u16(head, is64 ? 56 : 44)
puts "phoff=#{phoff} phentsize=#{phentsize} phnum=#{phnum}"
phdrs = Bytes.new(phentsize.to_i32 * phnum.to_i32)
f.seek(phoff)
f.read_fully(phdrs)
phnum.times do |i|
  base = i * phentsize
  t = u32(phdrs, base)
  off = is64 ? u64(phdrs, base+8) : u32(phdrs, base+4).to_u64
  sz  = is64 ? u64(phdrs, base+32) : u32(phdrs, base+16).to_u64
  puts "ph#{i}: type=#{t} off=#{off} size=#{sz}"
end
