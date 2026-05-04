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
if {[file exists $RPT_ROOT]} {
    echo "Directory $RPT_ROOT already exists"
} else {
    file mkdir $RPT_ROOT
    echo "Creating $RPT_ROOT"
}

if {[file exists $RPT_VERSION_DIR]} {
    echo "Recreating $RPT_VERSION_DIR"
    file delete -force $RPT_VERSION_DIR
    file mkdir $RPT_VERSION_DIR
} else {
    file mkdir $RPT_VERSION_DIR
    echo "Creating $RPT_VERSION_DIR"
}


if {[file exists $OUT_ROOT]} {
    echo "Directory $OUT_ROOT already exists"
} else {
    file mkdir $OUT_ROOT
    echo "Creating $OUT_ROOT"
}

if {[file exists $OUT_VERSION_DIR]} {
    echo "Recreating $OUT_VERSION_DIR"
    file delete -force $OUT_VERSION_DIR
    file mkdir $OUT_VERSION_DIR
} else {
    file mkdir $OUT_VERSION_DIR
    echo "Creating $OUT_VERSION_DIR"
}

# create work
if {[file exists $WORK_ROOT]} {
    echo "Directory $WORK_ROOT already exists"
} else {
    file mkdir $WORK_ROOT
    echo "Creating $WORK_ROOT"
}

if {[file exists $WORK_VERSION_DIR]} {
    echo "Directory $WORK_VERSION_DIR already exists"
} else {
    file mkdir $WORK_VERSION_DIR
    echo "Creating $WORK_VERSION_DIR"
}
