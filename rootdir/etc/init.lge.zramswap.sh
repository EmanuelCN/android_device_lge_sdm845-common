#!/vendor/bin/sh

target=`getprop ro.board.platform`
device=`getprop ro.product.device`
product=`getprop ro.product.name`

start() {
  # Check the available memory
  memtotal_str=$(grep 'MemTotal' /proc/meminfo)
  memtotal_tmp=${memtotal_str#MemTotal:}
  memtotal_kb=${memtotal_tmp%kB}

  echo MemTotal is $memtotal_kb kB

  #check built-in zram devices
  nr_builtin_zram=$(ls /dev/block/zram* | grep -c zram)

  if [ "$nr_builtin_zram" -ne "0" ] ; then
    #use the built-in zram devices
    nr_zramdev=${nr_builtin_zram}
    use_mod=0
  else
    use_mod=1
    # Detect the number of cores
    nr_cores=$(grep -c ^processor /proc/cpuinfo)

    # Evaluate the number of zram devices based on the number of cores.
    nr_zramdev=${nr_cores/#0/1}
    echo The number of cores is $nr_cores
  fi
  echo zramdev $nr_zramdev

  # Add zram tunable parameters
  # you can set "compr_zram=lzo" or "compr_zram=lz4"
  # but when you set "zram=lz4", you must set "CONFIG_ZRAM_LZ4_COMPRESS=y"
  compr_zram=lz4
  nr_multi_zram=1
  sz_zram0=0
  zram_async=0
  swappiness_new=80

  case $target in
    "msm8937")
      compr_zram=lz4
      nr_multi_zram=4
      zram_async=0
      max_write_threads=0
      if [ $nr_zramdev -gt 1 ] ; then
        sz_zram0=$(( memtotal_kb / 8 * 3 ))
        sz_zram=$(( memtotal_kb / 4 ))
      else
        if [ memtotal_kb -gt 2048000 ] ; then
          sz_zram=$(( memtotal_kb / 4 / ${nr_zramdev} ))
        else
          sz_zram=$(( memtotal_kb / 3 / ${nr_zramdev} ))
        fi
      fi
    ;;

    "msm8953")
      sz_zram=$(( memtotal_kb / 4 ))
      sz_zram0=$(( memtotal_kb / 4 ))
      compr_zram=lz4
      nr_multi_zram=4
      if [ memtotal_kb -gt 2048000 ] ; then
        zram_async=1
        max_write_threads=4
      else
        zram_async=0
        max_write_threads=0
      fi
    ;;

    "msm8998" | "msm8996" | "msm8952")
      sz_zram=$(( memtotal_kb / 4 ))
      sz_zram0=$(( memtotal_kb / 4 ))
      compr_zram=lz4
      nr_multi_zram=4
    ;;

    "sdm845" | "msmnile" | "sm6150")
      sz_zram=3145728
      sz_zram0=3145728
      compr_zram=lz4
      nr_multi_zram=4
      zram_async=1
      max_write_threads=8

      # Must use == expression instead of -eq to compare string
      if [ "$target" == "msmnile" ] ; then
        # increase watermark about 2%
        echo 200 > /proc/sys/vm/watermark_scale_factor
      fi
    ;;

    "kona")
      # use zram0 (50% of memtotal) only for hswap feature
      # set 3GB zram size for the over 8GB DDR model
      if [ $memtotal_kb -gt 6291456 ] ; then
        sz_zram=3145728
      else
        sz_zram=$(( memtotal_kb / 2 ))
      fi
      compr_zram=lz4
      nr_multi_zram=4
      # increase watermark about 2%
      echo 200 > /proc/sys/vm/watermark_scale_factor
      # disable watermark boost feature
      echo 0 > /proc/sys/vm/watermark_boost_factor
	;;

    "lito")
      # use zram0 only for hswap feature
      sz_zram=$(( memtotal_kb / 2 ))
      compr_zram=lz4
      nr_multi_zram=4
      # increase watermark about 2%
      echo 0 > /proc/sys/vm/watermark_boost_factor
      echo 200 > /proc/sys/vm/watermark_scale_factor
    ;;

    *)
      sz_zram=$(( memtotal_kb / 4 / ${nr_zramdev} ))
    ;;
  esac

  echo sz_zram size is ${sz_zram}

  # load kernel module for zram
  if [ "$use_mod" -eq "1"  ] ; then
    modpath=/system/lib/modules/zram.ko
    modargs="num_devices=${nr_zramdev}"
    echo zram.ko is $modargs

    if [ -f $modpath ] ; then
      insmod $modpath $modargs && (echo "zram module loaded") || (echo "module loading failed and exiting(${?})" ; exit $?)
    else
      echo "zram module not exist(${?})"
      exit $?
    fi
  fi

  # initialize and configure the zram devices as a swap partition
  zramdev_num=0
  if [ "$sz_zram0" -eq "0" ] ; then
    sz_zram0=$((${sz_zram} * ${nr_zramdev}))
  fi
  swap_prio=5
  while [[ $zramdev_num -lt $nr_zramdev ]]; do
    modpath_comp_streams=/sys/block/zram${zramdev_num}/max_comp_streams
    modpath_comp_algorithm=/sys/block/zram${zramdev_num}/comp_algorithm
    # If compr_zram is not available, then use default zram comp_algorithm
    available_comp_algorithm="$(cat $modpath_comp_algorithm | grep $compr_zram)"
    if [ "$available_comp_algorithm" ]; then
      if [ -f $modpath_comp_streams ] ; then
        echo $nr_multi_zram > /sys/block/zram${zramdev_num}/max_comp_streams
      fi
      if [ -f $modpath_comp_algorithm ] ; then
        echo $compr_zram > /sys/block/zram${zramdev_num}/comp_algorithm
      fi
    fi
    if [ "$zramdev_num" -ne "0" ] ; then
      echo ${sz_zram}k > /sys/block/zram${zramdev_num}/disksize
    else
      if [ "$zram_async" -ne "0" ] ; then
        echo $zram_async > /sys/block/zram${zramdev_num}/async
        echo $max_write_threads > /sys/block/zram${zramdev_num}/max_write_threads
      fi
      echo ${sz_zram0}k > /sys/block/zram${zramdev_num}/disksize
    fi
    mkswap /dev/block/zram${zramdev_num} && (echo "mkswap ${zramdev_num}") || (echo "mkswap ${zramdev_num} failed and exiting(${?})" ; exit $?)
    swapon -p $swap_prio /dev/block/zram0 && (echo "swapon ${zramdev_num}") || (echo "swapon ${zramdev_num} failed and exiting(${?})" ; exit $?)
    ((zramdev_num++))
    ((swap_prio++))
  done

  # tweak VM parameters considering zram/swap

  #deny_minfree_change=`getprop ro.lge.deny.minfree.change`
  deny_minfree_change=0

  overcommit_memory=1
  page_cluster=0
  if [ "$deny_minfree_change" -ne "1" ] ; then
	let min_free_kbytes=$(cat /proc/sys/vm/min_free_kbytes)*2
  fi
  laptop_mode=0

  echo $swappiness_new > /proc/sys/vm/swappiness
  echo $overcommit_memory > /proc/sys/vm/overcommit_memory
  echo $page_cluster > /proc/sys/vm/page-cluster
  if [ "$deny_minfree_change" -ne "1" ] ; then
	echo $min_free_kbytes > /proc/sys/vm/min_free_kbytes
  fi
  echo $laptop_mode > /proc/sys/vm/laptop_mode
}

stop() {
  swaps=$(grep zram /proc/swaps)
  swaps=${swaps%%partition*}
  if [ $swaps ] ; then
    for i in $swaps; do
     swapoff $i
    done
    for j in $(ls /sys/block | grep zram); do
      echo 1 ${j}/reset
    done
    if [ $(lsmod | grep -c zram) -ne "0" ] ; then
      rmmod zram && (echo "zram unloaded") || (echo "zram unload fail(${?})" ; exit $?)
    fi
  fi
}

cmd=${1-start}

case $cmd in
  "start") start
  ;;
  "stop") stop
  ;;
  *) echo "Undefined command!"
  ;;
esac
