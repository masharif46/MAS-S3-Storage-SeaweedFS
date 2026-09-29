# Storage usage

One S3 identity can access multiple buckets. The usage checker therefore takes one identity and one or more repeatable bucket options:

```bash
sudo ./check-storage-usage.sh \
  --identity laravel-dev \
  --bucket laravel-dev \
  --bucket laravel-assets
```

It reports each bucket's S3 object count and size, the combined S3 size, and the host filesystem usage for `/opt/mas-storage-seaweedfs`.

The old positional form remains supported:

```bash
sudo ./check-storage-usage.sh laravel-dev laravel-dev
```

Here, the first value is the identity and the second is the bucket. They are equal only when the project uses the same naming convention for both.
