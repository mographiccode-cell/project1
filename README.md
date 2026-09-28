# Aman Player — أمان بلاير

مشغل فيديو محلي وآمن مبني باستخدام **Flutter**، مصمم ليقدم تجربة تشغيل سريعة وقريبة من تطبيقات مثل MX Player وVLC مع واجهة عربية ودعم RTL.

## الإصدار الحالي
**v0.3.0+3**

> Android applicationId الثابت للمشروع: `com.mahmoud.amanplayer`  
> يجب عدم تغييره في أي تحديث لاحق حتى تبقى التحديثات متوافقة مع النسخ المثبتة وبيانات التطبيق المحلية.

## المزايا
- عرض فيديوهات الجهاز محليًا.
- البحث في الفيديوهات والمجلدات.
- عرض قائمة أو شبكة.
- أقسام: كل الفيديوهات، الفيديوهات الجديدة، المجلدات، متابعة المشاهدة، المفضلة.
- ترتيب حسب الأحدث، الأقدم، الاسم، والمدة.
- حفظ آخر موضع مشاهدة محليًا.
- قائمة تشغيل والتنقل بين الفيديوهات.
- السحب الأفقي للتقديم والتأخير داخل الفيديو.
- التحكم بالإضاءة والصوت بالسحب العمودي.
- قفل عناصر التحكم أثناء المشاهدة.
- أوضاع عرض متعددة: احتواء، قص، تمديد، ملاءمة العرض، وملاءمة الارتفاع.
- تغيير سرعة التشغيل.
- دعم المسارات والترجمات وإضافة ملفات ترجمة خارجية.
- التحكم بحجم الترجمة وتأخيرها.
- إعادة تسمية الفيديو ونقله إلى سلة المحذوفات عبر MediaStore عند دعم الجهاز.
- دعم الوضع الفاتح والداكن.
- واجهة عربية RTL.

## الخصوصية
Aman Player يعمل بأسلوب **Local-first**:
- لا يحتاج إلى حساب.
- لا يحتوي ملف Android الحالي على صلاحية Internet.
- بيانات التفضيلات والمفضلة والسجل وموضع المشاهدة تحفظ محليًا على الجهاز.
- Android Backup معطل في ملف Manifest الحالي.

## التقنيات
- Flutter / Dart
- media_kit
- media_kit_video
- media_kit_libs_video
- photo_manager
- shared_preferences
- screen_brightness
- path_provider
- file_picker

## ملفات المصدر
حزمة المصدر الكاملة المحفوظة للإصدار الحالي موجودة في:
`releases/AmanPlayer-v0.3.0-source.tar.xz`

وتحتوي على كود Flutter الفعلي، بما في ذلك:
```text
lib/
  main.dart
  models/video_item.dart
  pages/home_page.dart
  pages/player_page.dart
  services/media_library_service.dart
  services/preferences_service.dart
  widgets/video_thumbnail.dart
android/app/src/main/AndroidManifest.xml
assets/branding/README.txt
pubspec.yaml
```

كما توجد الملفات الأساسية القابلة للقراءة مباشرة في المستودع.

## تشغيل المشروع
بعد فك حزمة المصدر، وإذا كانت ملفات منصة Android المولدة غير موجودة:

```bash
flutter create . --platforms=android
flutter pub get
flutter run
```

بعد التوليد تأكد أن `namespace` و`applicationId` هما:
```text
com.mahmoud.amanplayer
```

ويجب أن يكون `MainActivity` ضمن نفس package.

## بناء APK
```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

المسار المعتاد:
```text
build/app/outputs/flutter-apk/app-release.apk
```

## متطلبات Android
- `READ_MEDIA_VIDEO` للإصدارات الحديثة.
- `READ_EXTERNAL_STORAGE` للأجهزة القديمة حتى API 32.

## حالة المستودع
هذا المستودع يمثل أحدث نسخة مصدر محفوظة حاليًا من **Aman Player v0.3.0**. سيتم استخدامه كنقطة النشر الرسمية للنسخ اللاحقة.

## المطور
**تصميم وبرمجة : م.محمود دغَبس  مبايل:774813824**

## الحقوق
Copyright © 2026 م.محمود دغَبس. All rights reserved.

المستودع متاح للعرض العام. نشر المصدر كـ Public لا يمنح ترخيصًا تلقائيًا لإعادة الاستخدام أو إعادة التوزيع أو النشر التجاري.
