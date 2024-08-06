# LiveSync Obsidian: CouchDB, Nginx, Certbot

Автоматическая сборка сервера CouchDB с доменном и SSL-сертификацией

## Оглавление

- [Требования](#требования)
- [Данные](#данные)
- [Установка](#установка)


## Требования

- Ubuntu
- Docker & Docker Compose

## Данные

- [x] Запрос логина и пароля CouchDB. (Шифрование пароля не настроено, пароль хранится в открытом виде)
- [x] Запрос директории установки файлов решения. (Требуется указывать ```слеш``` только в начале: ```/DIR```)
- [x] Запрос доменного имени. (Реализация через ```localhost``` пока не настроена, да и не вижу в этом смысла, т.к. для синхронизации на смартфонах требуется SSL)
- [x] Запрос выбора ```HTTP``` или ```HTTPS```.
- [x] Запрос интервала проверки SSL сертификата. (Интервал указывается в часах - к сожалению пока не тестировалось обновление) 

## Установка

После загрузки файла на сервер, требуется сделать его исполняющим: ```chmod +x setup.sh```

Скрипт автоматически проверит установку ```Docker``` & ```Docker Compose```. В случае отсутстивия установок - автоматически установит их.

---

### Учётные записи CouchDB

Для авторизации в [LiveSync-Obsidian](https://github.com/vrtmrz/obsidian-livesync) вы можете использовать суперпользователя, которого создавали при выполнелнении [setup.sh](https://github.com/CoplandTech/LiveSyncObsidian--CouchDB_Nginx_Certbot/blob/main/setup.sh), но в таком случае при указании ```базы данных``` в настройках плагина Вы будете создавать новые БД без чёткого разделения: Пользователь - База.

#### Настройка CouchDB с помощью CMD Windows
| Переменная | Описание : Значение |
| ------------- | ------------- |
| URL_COUCHDB | Адрес вашей установки CouchDB : example.com |
| ADMIN_USER | Имя администратора !!Регистр важен!!, созданого при выполнении [setup.sh](https://github.com/CoplandTech/LiveSyncObsidian--CouchDB_Nginx_Certbot/blob/main/setup.sh) : Admin |
| ADMIN_PASS | Пароль администратора, созданого при выполнении [setup.sh](https://github.com/CoplandTech/LiveSyncObsidian--CouchDB_Nginx_Certbot/blob/main/setup.sh) : 1q2w3e |
| USER_NAME | Желаемое имя пользователя : Test1 |
| USER_PASS | Желаемый пароль пользователя : PaSsWoRd |
| DATA_BASE | Имя Базы Данных : sync_test1 |

1. Созадть пользователя:
```cmd
curl -X PUT https://ADMIN_USER:ADMIN_PASS@URL_COUCHDB/_users/org.couchdb.user:USER_NAME -H "Content-Type: application/json" -d "{\"name\": \"USER_NAME\", \"password\": \"USER_PASS\", \"roles\": [], \"type\": \"user\"}"
```

2. Создать базу данных пользователя:
```cmd
curl -X PUT https://ADMIN_USER:ADMIN_PASS@URL_COUCHDB/DATA_BASE
```

3. Назначить права доступа к БД:
В примере: Пользователь - Администратор БД
```cmd
curl -X PUT https://ADMIN_USER:ADMIN_PASS@URL_COUCHDB/DATA_BASE/_security -H "Content-Type: application/json" -d "{\"admins\": {\"names\": [\"USER_NAME\"],\"roles\": []}}"
``` 
 
