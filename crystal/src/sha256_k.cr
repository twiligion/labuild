# FIPS 180-4 SHA-256 round constants and initial hash value.
#
# Kept next to the implementation so `labuild-core` stays a single static
# binary with no crypto library dependency (Crystal's Digest::SHA256 links
# libcrypto, which abuild helpers should not pull in).

SHA256_K = StaticArray[
  0x428a2f98_u32, 0x71374491_u32, 0xb5c0fbcf_u32, 0xe9b5dba5_u32,
  0x3956c25b_u32, 0x59f111f1_u32, 0x923f82a4_u32, 0xab1c5ed5_u32,
  0xd807aa98_u32, 0x12835b01_u32, 0x243185be_u32, 0x550c7dc3_u32,
  0x72be5d74_u32, 0x80deb1fe_u32, 0x9bdc06a7_u32, 0xc19bf174_u32,
  0xe49b69c1_u32, 0xefbe4786_u32, 0x0fc19dc6_u32, 0x240ca1cc_u32,
  0x2de92c6f_u32, 0x4a7484aa_u32, 0x5cb0a9dc_u32, 0x76f988da_u32,
  0x983e5152_u32, 0xa831c66d_u32, 0xb00327c8_u32, 0xbf597fc7_u32,
  0xc6e00bf3_u32, 0xd5a79147_u32, 0x06ca6351_u32, 0x14292967_u32,
  0x27b70a85_u32, 0x2e1b2138_u32, 0x4d2c6dfc_u32, 0x53380d13_u32,
  0x650a7354_u32, 0x766a0abb_u32, 0x81c2c92e_u32, 0x92722c85_u32,
  0xa2bfe8a1_u32, 0xa81a664b_u32, 0xc24b8b70_u32, 0xc76c51a3_u32,
  0xd192e819_u32, 0xd6990624_u32, 0xf40e3585_u32, 0x106aa070_u32,
  0x19a4c116_u32, 0x1e376c08_u32, 0x2748774c_u32, 0x34b0bcb5_u32,
  0x391c0cb3_u32, 0x4ed8aa4a_u32, 0x5b9cca4f_u32, 0x682e6ff3_u32,
  0x748f82ee_u32, 0x78a5636f_u32, 0x84c87814_u32, 0x8cc70208_u32,
  0x90befffa_u32, 0xa4506ceb_u32, 0xbef9a3f7_u32, 0xc67178f2_u32,
]

SHA256_H0 = StaticArray[
  0x6a09e667_u32, 0xbb67ae85_u32, 0x3c6ef372_u32, 0xa54ff53a_u32,
  0x510e527f_u32, 0x9b05688c_u32, 0x1f83d9ab_u32, 0x5be0cd19_u32,
]
