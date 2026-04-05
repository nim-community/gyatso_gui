# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

# Performance optimizations
switch("opt", "speed")
switch("passC", "-O3 -march=native -mtune=native -flto")
switch("passL", "-O3 -flto")

# SIMD support - AVX2 for modern CPUs
switch("define", "avx2")
# switch("define", "avx512")  # Uncomment for AVX512 (newer CPUs only)

# Other performance flags
# switch("define", "release")
# switch("exceptions", "quirky")  # Faster exception handling
