ExUnit.start(exclude: [:integration], capture_log: true)
Mimic.copy(LLMDB)
Mimic.copy(System)
Mimic.copy(Sycophant.Transport)
