# Android c-ares 支持 DNS

## c-ares 链路分析

```c
ares_status_t ares_init_by_sysconfig(ares_channel_t *channel)
{
  ares_status_t    status;
  ares_sysconfig_t sysconfig;

  memset(&sysconfig, 0, sizeof(sysconfig));
  sysconfig.ndots = 1; /* Default value if not otherwise set */

#if defined(USE_WINSOCK)
  status = ares_init_sysconfig_windows(channel, &sysconfig);
#elif defined(__MVS__)
  status = ares_init_sysconfig_mvs(channel, &sysconfig);
#elif defined(__riscos__)
  status = ares_init_sysconfig_riscos(channel, &sysconfig);
#elif defined(WATT32)
  status = ares_init_sysconfig_watt32(channel, &sysconfig);
#elif defined(ANDROID) || defined(__ANDROID__)
  status = ares_init_sysconfig_android(channel, &sysconfig);
#elif defined(__APPLE__)
  status = ares_init_sysconfig_macos(channel, &sysconfig);
#elif defined(CARES_USE_LIBRESOLV)
  status = ares_init_sysconfig_libresolv(channel, &sysconfig);
#elif defined(__QNX__)
  status = ares_init_sysconfig_qnx(channel, &sysconfig);
#else
  status = ares_init_sysconfig_files(channel, &sysconfig, ARES_TRUE);
#endif
```

Android 进入

```bash
ares_init_sysconfig_android
```

```c
#if defined(ANDROID) || defined(__ANDROID__)
static ares_status_t ares_init_sysconfig_android(const ares_channel_t *channel,
                                                 ares_sysconfig_t *sysconfig)
{
  size_t        i;
  char        **dns_servers;
  char         *domains;
  size_t        num_servers;
  ares_status_t status = ARES_EFILE;

  DEBUGF(fprintf(stderr, "c-ares: android sysconfig start\n"));

  /* Use the Android connectivity manager to get a list
   * of DNS servers. As of Android 8 (Oreo) net.dns#
   * system properties are no longer available. Google claims this
   * improves privacy. Apps now need the ACCESS_NETWORK_STATE
   * permission and must use the ConnectivityManager which
   * is Java only. */
  dns_servers = ares_get_android_server_list(MAX_DNS_PROPERTIES, &num_servers);
  DEBUGF(fprintf(stderr, "c-ares: android dns server list %s\n",
                 dns_servers != NULL ? "available" : "unavailable"));
  if (dns_servers != NULL) {
    DEBUGF(fprintf(stderr, "c-ares: android dns server count=%zu\n",
                   num_servers));
    for (i = 0; i < num_servers; i++) {
      DEBUGF(fprintf(stderr, "c-ares: android dns[%zu]='%s'\n", i,
                     dns_servers[i] != NULL ? dns_servers[i] : "(null)"));
      status = ares_sconfig_append_fromstr(channel, &sysconfig->sconfig,
                                           dns_servers[i], ARES_TRUE);
      if (status != ARES_SUCCESS) {
        DEBUGF(fprintf(stderr,
                       "c-ares: android dns append failed: %s\n",
                       ares_strerror(status)));
        break;
      }
    }
    for (i = 0; i < num_servers; i++) {
      ares_free(dns_servers[i]);
    }
    ares_free(dns_servers);
    if (status != ARES_SUCCESS) {
      return status;
    }
  }

  domains            = ares_get_android_search_domains_list();
  DEBUGF(fprintf(stderr, "c-ares: android search domains raw=%s\n",
                 domains != NULL ? domains : "(null)"));
  sysconfig->domains = ares_strsplit(domains, ", ", &sysconfig->ndomains);
  DEBUGF(fprintf(stderr, "c-ares: android search domain count=%zu\n",
                 sysconfig->ndomains));
  ares_free(domains);

#  ifdef HAVE___SYSTEM_PROPERTY_GET
  /* Old way using the system property still in place as
   * a fallback. Older android versions can still use this.
   * it's possible for older apps not not have added the new
   * permission and we want to try to avoid breaking those.
   *
   * We'll only run this if we don't have any dns servers
   * because this will get the same ones (if it works). */
  if (sysconfig->sconfig == NULL) {
    char propname[PROP_NAME_MAX];
    char propvalue[PROP_VALUE_MAX] = "";

    DEBUGF(fprintf(stderr,
                   "c-ares: android dns fallback to system properties\n"));
    for (i = 1; i <= MAX_DNS_PROPERTIES; i++) {
      snprintf(propname, sizeof(propname), "%s%zu", DNS_PROP_NAME_PREFIX, i);
      if (__system_property_get(propname, propvalue) < 1) {
        DEBUGF(fprintf(stderr,
                       "c-ares: android property %s unavailable\n",
                       propname));
        break;
      }
      DEBUGF(fprintf(stderr, "c-ares: android property %s='%s'\n", propname,
                     propvalue));
      status = ares_sconfig_append_fromstr(channel, &sysconfig->sconfig,
                                           propvalue, ARES_TRUE);
      if (status != ARES_SUCCESS) {
        DEBUGF(fprintf(stderr,
                       "c-ares: android property append failed: %s\n",
                       ares_strerror(status)));
        return status;
      }
    }
  }
#  endif /* HAVE___SYSTEM_PROPERTY_GET */

  DEBUGF(fprintf(stderr,
                 "c-ares: android sysconfig done status=%s servers=%s domains=%zu\n",
                 ares_strerror(status),
                 sysconfig->sconfig != NULL ? "configured" : "missing",
                 sysconfig->ndomains));

  return status;
}
#endif
```

ares_init_sysconfig_android 函数会优先尝试通过 Android 的 ConnectivityManager Java API 获取 DNS 服务器列表，并将其添加到 c-ares 的配置中。如果这条路径失败，再回退到旧的系统属性方法 `net.dns#`（Android 8 之前的旧方案）。

```c
char **ares_get_android_server_list(size_t max_servers, size_t *num_servers)
{
  JNIEnv     *env             = NULL;
  jobject     active_network  = NULL;
  jobject     link_properties = NULL;
  jobject     server_list     = NULL;
  jobject     server          = NULL;
  jstring     str             = NULL;
  jint        nserv;
  const char *ch_server_address;
  int         res;
  size_t      i;
  char      **dns_list     = NULL;
  int         need_detatch = 0;

  if (android_jvm == NULL || android_connectivity_manager == NULL ||
      max_servers == 0 || num_servers == NULL) {
    DEBUGF(fprintf(stderr,
                   "c-ares: android server_list precheck failed jvm=%p cm=%p max=%zu num_ptr=%p\n",
                   (void *)android_jvm, (void *)android_connectivity_manager,
                   max_servers, (void *)num_servers));
    return NULL;
  }

  if (android_cm_active_net_mid == NULL || android_cm_link_props_mid == NULL ||
      android_lp_dns_servers_mid == NULL || android_list_size_mid == NULL ||
      android_list_get_mid == NULL || android_ia_host_addr_mid == NULL) {
    return NULL;
  }

  res = (*android_jvm)->GetEnv(android_jvm, (void **)&env, JNI_VERSION_1_6);
  if (res == JNI_EDETACHED) {
    env          = NULL;
    res          = jvm_attach(&env);
    need_detatch = 1;
  }
  if (res != JNI_OK || env == NULL) {
    goto done;
  }

  /* JNI below is equivalent to this Java code.
     import android.content.Context;
     import android.net.ConnectivityManager;
     import android.net.LinkProperties;
     import android.net.Network;
     import java.net.InetAddress;
     import java.util.List;

     ConnectivityManager cm = (ConnectivityManager)this.getApplicationContext()
       .getSystemService(Context.CONNECTIVITY_SERVICE);
     Network an = cm.getActiveNetwork();
     LinkProperties lp = cm.getLinkProperties(an);
     List<InetAddress> dns = lp.getDnsServers();
     for (InetAddress ia: dns) {
       String ha = ia.getHostAddress();
     }

     Note: The JNI ConnectivityManager object and all method IDs were previously
           initialized in ares_library_init_android.
   */

  active_network = (*env)->CallObjectMethod(env, android_connectivity_manager,
                                            android_cm_active_net_mid);
  if (active_network == NULL) {
    goto done;
  }

  link_properties =
    (*env)->CallObjectMethod(env, android_connectivity_manager,
                             android_cm_link_props_mid, active_network);
  if (link_properties == NULL) {
    goto done;
  }

  server_list =
    (*env)->CallObjectMethod(env, link_properties, android_lp_dns_servers_mid);
  if (server_list == NULL) {
    goto done;
  }

  nserv = (*env)->CallIntMethod(env, server_list, android_list_size_mid);
  if (nserv > (jint)max_servers) {
    nserv = (jint)max_servers;
  }
  if (nserv <= 0) {
    goto done;
  }
  *num_servers = (size_t)nserv;

  dns_list = ares_malloc(sizeof(*dns_list) * (*num_servers));
  for (i = 0; i < *num_servers; i++) {
    size_t len = 64;
    server =
      (*env)->CallObjectMethod(env, server_list, android_list_get_mid, (jint)i);
    dns_list[i]    = ares_malloc(len);
    dns_list[i][0] = 0;
    if (server == NULL) {
      continue;
    }
    str = (*env)->CallObjectMethod(env, server, android_ia_host_addr_mid);
    ch_server_address = (*env)->GetStringUTFChars(env, str, 0);
    ares_strcpy(dns_list[i], ch_server_address, len);
    (*env)->ReleaseStringUTFChars(env, str, ch_server_address);
    (*env)->DeleteLocalRef(env, str);
    (*env)->DeleteLocalRef(env, server);
  }

done:
  if ((*env)->ExceptionOccurred(env)) {
    (*env)->ExceptionClear(env);
  }

  if (server_list != NULL) {
    (*env)->DeleteLocalRef(env, server_list);
  }
  if (link_properties != NULL) {
    (*env)->DeleteLocalRef(env, link_properties);
  }
  if (active_network != NULL) {
    (*env)->DeleteLocalRef(env, active_network);
  }

  if (need_detatch) {
    (*android_jvm)->DetachCurrentThread(android_jvm);
  }
  return dns_list;
}

```

这部分为 ares_get_android_server_list 通过 JNI 获取 DNS 地址的代码。

从代码逻辑看，`ares_get_android_server_list()` 并不是一进来就直接执行 JNI 调用，而是先做一层前置检查：

1. `android_jvm` 不能为 `NULL`
2. `android_connectivity_manager` 不能为 `NULL`
3. `max_servers` 不能为 `0`
4. `num_servers` 不能为 `NULL`

只有这些条件都满足，它才会继续往下执行 `GetEnv`、`getActiveNetwork()`、`getLinkProperties()`、`getDnsServers()` 这一整条 JNI 链。

因此，只要命中这段：

```c
if (android_jvm == NULL || android_connectivity_manager == NULL ||
    max_servers == 0 || num_servers == NULL) {
  DEBUGF(fprintf(stderr,
                 "c-ares: android server_list precheck failed jvm=%p cm=%p max=%zu num_ptr=%p\n",
                 (void *)android_jvm, (void *)android_connectivity_manager,
                 max_servers, (void *)num_servers));
  return NULL;
}
```

就说明函数是在入口 precheck 直接返回，后续 JNI 主路径根本没有执行。

最终执行日志

```bash
adb push android-output/arm64-v8a/static/bin/curl /tmp/curl-ares-debug
adb shell chmod +x /tmp/curl-ares-debug
adb shell '/tmp/curl-ares-debug http://www.baidu.com/ -o /dev/null -sS -v 2>&1 | head -80'
android-output/arm64-v8a/static/bin/curl: 1 file pushed, 0 skipped. 152.8 MB/s (8947072 bytes in 0.056s)
c-ares: android sysconfig start
c-ares: android server_list precheck failed jvm=0x0 cm=0x0 max=8 num_ptr=0x7ff699f698
c-ares: android dns server list unavailable
c-ares: android search domains raw=(null)
c-ares: android search domain count=0
c-ares: android dns fallback to system properties
c-ares: android property net.dns1 unavailable
c-ares: android sysconfig done status=Error reading file servers=missing domains=0
Error: init_by_sysconfig failed: Error reading file
* Could not resolve host: www.baidu.com (Could not contact DNS servers)
* Could not resolve host: www.baidu.com
* shutting down connection #0
curl: (6) Could not resolve host: www.baidu.com (Could not contact DNS servers)
```

根据这次实际运行日志，可以把控制流解释成下面这样：

1. `ares_init_sysconfig_android()` 已经被调用，说明 c-ares 确实走到了 Android 专用 sysconfig 分支。
2. `ares_get_android_server_list()` 一进入就打印了：

```text
c-ares: android server_list precheck failed jvm=0x0 cm=0x0 ...
```

1. 这说明 `android_jvm == NULL`，同时 `android_connectivity_manager == NULL`。
2. 因此前置检查直接失败，函数立刻 `return NULL`。
3. 所以后面的 JNI 调用，包括 `GetEnv`、`getActiveNetwork()`、`getLinkProperties()`、`getDnsServers()`，这次运行里都没有执行。
4. `ares_init_sysconfig_android()` 看到返回值为 `NULL`，于是打印 `android dns server list unavailable`。
5. 随后它再去取 search domains，但拿到的是 `NULL`，于是：

```text
c-ares: android search domains raw=(null)
c-ares: android search domain count=0
```

这里的 `android search domain count=0` 只表示“没有拿到任何搜索域后缀”，不是主故障点。真正的主故障点仍然是前面一个 DNS server 都没有拿到。
8. 因为 `sysconfig->sconfig == NULL`，所以继续进入 `net.dns#` fallback。
9. 但 `net.dns1` 也不可用，于是最终 `servers=missing`，整个 sysconfig 初始化失败。

因此，这次结论不是“JNI 在中途某一步调用失败”，而是“JNI 主路径因为缺少 `android_jvm` 和 `android_connectivity_manager`，在入口 precheck 就直接返回了”。

关于 `android dns fallback to system properties` 这一步为什么也没读到，需要再补一层说明：

1. 这里调用的不是环境变量，也不是直接读取 `build.prop` 文本文件。
2. `__system_property_get("net.dns1", propvalue)` 读的是 Android 运行时的 system property。
3. c-ares 的这段旧 fallback 依赖 `net.dns1`、`net.dns2` 这类 property 当前仍然对 native 代码可见。
4. 但从源码注释本身就能看出，这条路径已经被当成旧方案处理：`As of Android 8 (Oreo) net.dns# system properties are no longer available.`
5. 因此这次日志里的：

```text
c-ares: android dns fallback to system properties
c-ares: android property net.dns1 unavailable
```

更准确地表示为：c-ares 已经进入了 system property fallback，但当前设备运行时的 Android property system 里，没有可供它读取的 `net.dns1` 值，或者该值对当前 native 进程不可见，所以 `__system_property_get()` 返回值小于 1，fallback 在第一项就终止了。

也就是说，这一步失败的原因不是“路径没执行”，而是“路径执行了，但旧的 `net.dns#` 数据源在当前 Android 环境下不可用”。

## 安卓支持读取 conf 的方法

为了验证 `/etc/resolv.conf` 这条链是否真的可用，后续将 `ares_init_by_sysconfig()` 中 Android 分支临时改成了直接走文件型 sysconfig：

```c
#elif defined(ANDROID) || defined(__ANDROID__)
  status = ares_init_sysconfig_files(channel, &sysconfig, ARES_TRUE);
```

这次修改的意义不是“修复 JNI”，而是强行绕过 Android 专用分支，直接验证 c-ares 在 Android 上读取 conf 文件的链路是否能工作。

如果这条修改生效，那么控制流就会从原来的：

1. `ares_init_sysconfig_android()`
2. JNI / ConnectivityManager
3. `net.dns#` system property fallback

变成：

1. `ares_init_sysconfig_files()`
2. 读取 `/etc/resolv.conf`
3. 按 resolv.conf 内容构造 nameserver 列表

这条修改已经验证有效，说明两个结论：

1. 先前“不能读 `/etc/resolv.conf`”并不是 c-ares 文件解析器本身失效。
2. 真正拦住 `/etc/resolv.conf` 的，是 Android 平台默认分支优先进入了 `ares_init_sysconfig_android()`，而不是文件型 sysconfig。

换句话说，之前的失败根因是“默认平台分支没走到 files 路径”，不是“files 路径本身不能用”。

因此，当前链路可以明确拆成两种模式：

### 原始 Android 分支

默认代码：

```c
#elif defined(ANDROID) || defined(__ANDROID__)
  status = ares_init_sysconfig_android(channel, &sysconfig);
```

特点：

1. 优先走 JNI / ConnectivityManager
2. 失败后走 `net.dns#` property fallback
3. 当前 curl CLI 场景里，JNI 前置对象为空，property 也不可用，因此拿不到 nameserver

### 让 Android 走 conf 文件链

修改后代码：

```c
#elif defined(ANDROID) || defined(__ANDROID__)
  status = ares_init_sysconfig_files(channel, &sysconfig, ARES_TRUE);
```

特点：

1. 不再依赖 JVM / ConnectivityManager
2. 不再依赖 `net.dns#`
3. 直接按 Unix 风格去读 `/etc/resolv.conf`
4. 在当前验证里，这条路径是可工作的

这说明如果目标是让当前 adb shell 下的纯 native curl 正常解析域名，那么从工程可行性上看，至少有两条现实路径：

1. 继续保留原始 Android 分支，但运行时或编译期显式提供 DNS server
2. 修改 c-ares，让 Android 在自动发现失败后继续 fallback 到 `ares_init_sysconfig_files()`，从而支持 `/etc/resolv.conf`

就当前实验结果而言，第二条路线已经被证明是技术上可行的。