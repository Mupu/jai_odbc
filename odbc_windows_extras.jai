
wchar_t :: u16;
SQL_SUCCEEDED :: inline (rc: int) -> bool { return rc & ~1 == 0; }