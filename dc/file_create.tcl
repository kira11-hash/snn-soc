# 可配置参数（本文件易变项集中在这里）
# 报告根目录，通常来自 set_env.tcl 的 RPT_DIR。
set RPT_ROOT $RPT_DIR
# 输出根目录，通常来自 set_env.tcl 的 OUT_DIR。
set OUT_ROOT $OUT_DIR
# 当前运行版本号，用于区分不同综合批次。
set VERSION_TAG $file_version
# WORK 根目录名，综合中间产物统一放这里。
set WORK_ROOT "WORK"

# 报告版本目录（报告根目录 + 版本号）。
set RPT_VERSION_DIR "$RPT_ROOT/$VERSION_TAG"
# 输出版本目录（输出根目录 + 版本号）。
set OUT_VERSION_DIR "$OUT_ROOT/$VERSION_TAG"
# WORK 版本目录（WORK 根目录 + 版本号）。
set WORK_VERSION_DIR "$WORK_ROOT/$VERSION_TAG"

# 新项目通常无需改；目录名来自 set_env.tcl 的 RPT_DIR/OUT_DIR/file_version。
# 如需调整目录结构或命名规则，再改这里。
if {[file exist $RPT_ROOT]} {
    echo "File $RPT_ROOT already exist"
} else {
    exec mkdir $RPT_ROOT
    echo "Creating $RPT_ROOT !!!"
}

if {[file exist $RPT_VERSION_DIR]} {
    echo "File $VERSION_TAG already exist"
    exec rm $RPT_VERSION_DIR -r
    exec mkdir $RPT_VERSION_DIR
    echo "Re-create $VERSION_TAG files"
} else {
    exec mkdir $RPT_VERSION_DIR
    echo "Creating $VERSION_TAG in $RPT_ROOT !!!"
}


if {[file exist $OUT_ROOT]} {
    echo "File $OUT_ROOT already exist"
} else {
    exec mkdir $OUT_ROOT
    echo "Creating $OUT_ROOT !!!"
}

if {[file exist $OUT_VERSION_DIR]} {
    echo "File $VERSION_TAG already exist"
    exec rm $OUT_VERSION_DIR -r
    exec mkdir $OUT_VERSION_DIR
    echo "Re-create $VERSION_TAG files"
} else {
    exec mkdir $OUT_VERSION_DIR
    echo "Creating $VERSION_TAG in $OUT_ROOT !!!"
}

# create work
if {[file exist $WORK_ROOT]} {
    echo "File $WORK_ROOT already exist"
} else {
    exec mkdir $WORK_ROOT
    echo "Creating $WORK_ROOT!!!"
}

if {[file exist $WORK_VERSION_DIR]} {
    echo "File $WORK_VERSION_DIR already exist"
} else {
    exec mkdir $WORK_VERSION_DIR
    echo "Creating $WORK_VERSION_DIR in $WORK_ROOT !!!"
}
