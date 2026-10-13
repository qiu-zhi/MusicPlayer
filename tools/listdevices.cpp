// 诊断工具：枚举系统音频输出设备与默认设备，排查耳机未被选中的原因
// 结果直接写入 exe 同目录的 devices.txt（避免 Windows 子系统/编码导致的控制台丢失）
#include <QCoreApplication>
#include <QMediaDevices>
#include <QAudioDevice>
#include <QFile>
#include <QTextStream>
#include <QDir>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>

int main(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);

    const QString path = QDir(QCoreApplication::applicationDirPath()).filePath("devices.txt");
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text))
        return 2;

    QTextStream ts(&f);
    ts.setEncoding(QStringConverter::Utf8);

    const QAudioDevice def = QMediaDevices::defaultAudioOutput();
    const QList<QAudioDevice> outs = QMediaDevices::audioOutputs();

    QJsonObject root;
    root.insert("outputCount", outs.size());
    root.insert("defaultDescription", def.description());
    root.insert("defaultId", QString::fromLatin1(def.id()));
    root.insert("defaultIsNull", def.isNull());

    QJsonArray arr;
    for (int i = 0; i < outs.size(); ++i) {
        const QAudioDevice &d = outs.at(i);
        QJsonObject o;
        o.insert("index", i);
        o.insert("description", d.description());
        o.insert("id", QString::fromLatin1(d.id()));
        o.insert("idHex", QString::fromLatin1(d.id().toHex()));
        o.insert("isDefault", d.isDefault());
        o.insert("isNull", d.isNull());
        o.insert("minChannels", d.minimumChannelCount());
        o.insert("maxChannels", d.maximumChannelCount());
        o.insert("minSampleRate", d.minimumSampleRate());
        o.insert("maxSampleRate", d.maximumSampleRate());
        o.insert("isFormatSupported", d.isFormatSupported(d.preferredFormat()));
        arr.append(o);
    }
    root.insert("devices", arr);

    ts << QString::fromUtf8(QJsonDocument(root).toJson(QJsonDocument::Indented));
    ts.flush();
    f.close();

    // 额外写一份人类可读版
    QFile f2(QDir(QCoreApplication::applicationDirPath()).filePath("devices.txt.readable"));
    if (f2.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
        QTextStream t2(&f2);
        t2.setEncoding(QStringConverter::Utf8);
        t2 << "音频输出设备清单 共 " << outs.size() << " 个\n";
        for (int i = 0; i < outs.size(); ++i) {
            const QAudioDevice &d = outs.at(i);
            t2 << "--- [" << i << "] ---\n";
            t2 << "  description : " << d.description() << "\n";
            t2 << "  id          : " << QString::fromLatin1(d.id()) << "\n";
            t2 << "  isDefault   : " << (d.isDefault() ? "true" : "false") << "\n";
            t2 << "  channels    : " << d.minimumChannelCount() << "-" << d.maximumChannelCount() << "\n";
            t2 << "  sampleRate  : " << d.minimumSampleRate() << "-" << d.maximumSampleRate() << "\n";
        }
        t2 << "系统默认输出 : " << def.description()
           << "  (null=" << (def.isNull() ? "true" : "false") << ")\n";
        t2.flush();
        f2.close();
    }

    return 0;
}
