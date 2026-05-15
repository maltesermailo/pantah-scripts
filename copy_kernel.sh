mkdir -p out/target/product/panther/vendor_dlkm/lib/modules/
mkdir -p out/target/product/panther/obj/KERNEL_OBJ/

#Copy boot images
cp ./out/target/product/panther/boot.img out/target/product/panther/hybris-boot.img
cp ./out/target/product/panther/boot.img out/target/product/panther/hybris-recovery.img

#Copy modules
cp device/google/pantah-kernels/6.1/*.ko out/target/product/panther/vendor_dlkm/lib/modules/
cp device/google/pantah-kernels/6.1/modules.builtin out/target/product/panther/obj/KERNEL_OBJ/
