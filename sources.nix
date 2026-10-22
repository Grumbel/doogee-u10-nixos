# Pinned upstream sources. The revisions are the ones rk3562deb's build.sh
# pins as known to boot on the Doogee U10.
{ fetchFromGitHub }:

{
  # Debian build for the U10: device trees, kernel defconfig and patches,
  # Seekwave Wi-Fi/Bluetooth driver and firmware, camera and Type-C drivers
  rk3562deb = fetchFromGitHub {
    owner = "tech4bot";
    repo = "rk3562deb";
    rev = "920d3572169db973006c35daf7c2913fc0dec5c2";
    hash = "sha256-70c1UemkHf3ClsxkfDnk7AH5eNaGV7N33k6uFQavL2c=";
  };

  # Rockchip BSP kernel, develop-6.1 branch
  kernel = fetchFromGitHub {
    owner = "rockchip-linux";
    repo = "kernel";
    rev = "8c290990fe7b45fc7ee8ee0896fddf822ac02b54";
    hash = "sha256-oypWcN9xRJrxXguKL8kL815ul5G5CGWYct5EnXjc9gY=";
  };

  # Rockchip vendor U-Boot (2017.09) as packaged by Firefly, rk356x/firefly-5.10
  u-boot = fetchFromGitHub {
    owner = "Firefly-rk-linux";
    repo = "u-boot";
    rev = "30d6e6f55d2b943c0910c3f69ccf4d302272ee71";
    hash = "sha256-HzQlj5I2AC4HW0d/fd7odEOA6fRB6HC43eID5qEaxeo=";
  };

  # Rockchip binary blobs: DDR init (v1.07), SPL, TF-A (BL31), OP-TEE (BL32)
  rkbin = fetchFromGitHub {
    owner = "rockchip-linux";
    repo = "rkbin";
    rev = "167d377195bfd956d679027b742bad9a68ceb726";
    hash = "sha256-ec4wOTI5sardslw4jpCLfyQ1tYLmShGodi92rHEl7Do=";
  };
}
