mkdir -p out/target/product/panther/vendor_dlkm/lib/modules/
mkdir -p out/target/product/panther/obj/KERNEL_OBJ/include/config

#Copy boot images
cp ./out/target/product/panther/boot.img out/target/product/panther/hybris-boot.img
cp ./out/target/product/panther/boot.img out/target/product/panther/hybris-recovery.img

#Copy modules
cp device/google/pantah-kernels/6.1/*.ko out/target/product/panther/vendor_dlkm/lib/modules/
cp device/google/pantah-kernels/6.1/modules.builtin out/target/product/panther/obj/KERNEL_OBJ/

#Copy kernel
cp device/google/pantah-kernels/6.1/Image.lz4 out/target/product/panther/kernel

#Copy .config
cp out-kernel/google/gs-6.1/out/pantah/dist/.config out/target/product/panther/obj/KERNEL_OBJ/.config
find ~/hadk/out-kernel -name 'kernel.release' -exec cp {} out/target/product/panther/obj/KERNEL_OBJ/include/config \;
