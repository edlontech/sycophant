ExUnit.start(exclude: [:integration, :recording], capture_log: true)
Mimic.copy(LLMDB)
Mimic.copy(System)
Mimic.copy(Sycophant.Transport)
