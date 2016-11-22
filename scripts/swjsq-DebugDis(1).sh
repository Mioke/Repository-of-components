#! /bin/bash

shell_dir=`dirname $0`

TARGET_NAME="swjsq"

IPA_TYPE="DebugDis"
EXPORT_METHOD="development"

DIR_PATH=/Volumes/LDC/Xunlei/KN_APP_2.0.4/swjsq

SIGN="iPhone Developer: dicong liu (Q7GG5982GB)"
PROFILE="c2a381b7-3952-4970-868b-c6bf69242a5d"

TEMP_DIR=$shell_dir/$TARGET_NAME.$IPA_TYPE

#ARCHIVE_PATH=$DIR_PATH/$TARGET_NAME/archive

if [ ! -d "$TEMP_DIR" ]; then
mkdir TEMP_DIR
fi


#rm -rf $ARCHIVE_PATH

#if [ -f "$TEMP_DIR" ]; then
#
#rm $TEMP_DIR
#
#else
#
#echo "no ipa file"
#
#fi

xcodebuild -workspace $DIR_PATH/$TARGET_NAME.xcworkspace -scheme $TARGET_NAME -configuration $IPA_TYPE clean archive CODE_SIGN_IDENTITY="$SIGN" PROVISIONING_PROFILE="$PROFILE" -archivePath $TEMP_DIR/$TARGET_NAME.xcarchive
if [ $? -neq 0 ]; then {
echo "构建失败"; exit -1;
}

DIR_EXPORT_OPTION="$shell_dir/temexportFormat.plist"
rm -rf $DIR_EXPORT_OPTION

echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\

<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\

<plist version=\"1.0\">\

<dict>\

<key>method</key>\

<string>$EXPORT_METHOD</string>\

<key>uploadBitcode</key>\

<false/>\

<key>compileBitcode</key>\

<false/>\

<key>uploadSymbols</key>\

<false/>\

</dict>\

</plist>\

" >> $DIR_EXPORT_OPTION
rvm use system

xcodebuild -exportArchive  -exportOptionsPlist $DIR_EXPORT_OPTION -archivePath $TEMP_DIR/$TARGET_NAME.xcarchive -exportPath $TEMP_DIR

#if [ ! -d "$ARCHIVE_PATH" ]; then
#
#mkdir $ARCHIVE_PATH
#
#fi


DATE=$( date +"%Y%m%d_%H%M%S")
ARCHIVE_NAME=$TARGET_NAME-$IPA_TYPE-$DATE.ipa

#cp $TEMP_DIR/$TARGET_NAME.ipa $ARCHIVE_PATH/$ARCHIVE_NAME
mv $TEMP_DIR/$TARGET_NAME.ipa $TEMP_DIR/$ARCHIVE_NAME
mv $TEMP_DIR/$TARGET_NAME.xcarchive $TEMP_DIR/$TARGET_NAME-$IPA_TYPE-$DATE.xcarchive
open $TEMP_DIR

#fir p $ARCHIVE_PATH/$ARCHIVE_NAME  -T 29b441056e1e17c984cb32fadadsdddd
#open 




























