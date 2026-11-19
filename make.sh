apt install cmake libuv1-dev liblz4-dev liblzma-dev libdouble-conversion-dev libdwarf-dev libunwind-dev \
  libaio-dev libgflags-dev libgoogle-glog-dev libgtest-dev libgmock-dev clang-format-14 clang-14 clang-tidy-14 lld-14 \
  libgoogle-perftools-dev google-perftools libssl-dev gcc-12 g++-12 libboost-all-dev build-essential

1.2 libfuse
wget https://github.com/libfuse/libfuse/releases/download/fuse-3.16.1/fuse-3.16.1.tar.gz
tar vzxf fuse-3.16.1.tar.gz
cd fuse-3.16.1/
mkdir build; cd build
apt install meson
meson setup ..
ninja
ninja install

1.3 RUST
#rust toolchains
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"

1.4 FoundationDB
# Download at https://github.com/apple/foundationdb/releases/tag/7.3.63
wget https://github.com/apple/foundationdb/releases/download/7.3.63/foundationdb-clients_7.3.63-1_amd64.deb
wget https://github.com/apple/foundationdb/releases/download/7.3.63/foundationdb-server_7.3.63-1_amd64.deb

dpkg -i foundationdb-clients_7.3.63-1_amd64.deb
dpkg -i foundationdb-server_7.3.63-1_amd64.deb

1.5 g++11
sudo apt update
sudo apt install gcc-11 g++-11 -y
sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 50 --slave /usr/bin/g++ g++ /usr/bin/g++-11
sudo update-alternatives --config gcc

2.2 Compile 
cmake -S . -B build \
  -DCMAKE_CXX_COMPILER=clang++-14 \
  -DCMAKE_C_COMPILER=clang-14 \
  -DCMAKE_CXX_FLAGS="-B/usr/lib/gcc/x86_64-linux-gnu/11 -isystem /usr/include/c++/11 -isystem /usr/include/x86_64-linux-gnu/c++/11" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DSHUFFLE_METHOD=g++11

cmake --build build -j 32

2.3 Check the Compiled Binary

root@node12:/home/lzh/fdp/3fs# ls -lrt build/bin/
total 2176652
-rwxr-xr-x 1 root root  98937688 Aug 13 16:07 monitor_collector_main
-rwxr-xr-x 1 root root 169619064 Aug 13 16:21 mgmtd_main
-rwxr-xr-x 1 root root 140797272 Aug 13 16:24 hf3fs-admin
-rwxr-xr-x 1 root root 200421800 Aug 13 16:29 hf3fs_fuse_main
-rwxr-xr-x 1 root root 149896336 Aug 13 16:29 migration_main
-rwxr-xr-x 1 root root 152156352 Aug 13 16:29 simple_example_main
-rwxr-xr-x 1 root root 305709760 Aug 13 16:30 storage_main
-rwxr-xr-x 1 root root 272112176 Aug 13 16:31 meta_main
-rwxr-xr-x 1 root root 387283328 Aug 13 16:31 storage_bench
-rwxr-xr-x 1 root root 351948624 Aug 13 16:32 admin_cli

source "$HOME/.cargo/env"
. "$HOME/.cargo/env"
