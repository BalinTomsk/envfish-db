rem -b makes sqlcmd stop on the first error and return a non-zero exit code,
rem so a failed build is visible to the caller instead of silently "succeeding".
sqlcmd -b -S localhost -E -d master -i %1
