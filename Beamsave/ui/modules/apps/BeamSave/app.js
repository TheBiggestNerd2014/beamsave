angular.module('beamng.apps')
.directive('beamSaveApp', [function () {
  return {
    templateUrl: '/ui/modules/apps/BeamSave/app.html',
    replace: true,
    restrict: 'EA',
    scope: true,
    controller: ['$scope', function ($scope) {
      $scope.tab = 'save';
      $scope.saveName = '';
      $scope.busy = false;
      $scope.saves = [];
      $scope.settings = {
        vehicleLoadMode: 'replace',
        autoSwitchMap: true,
        confirmBeforeDeleting: true,
        restoreVelocity: true,
        restoreMechanicalState: true,
        restoreDamage: false,
        restoreLights: true,
        savePlayerVehicle: true,
        saveAllVehicles: true,
        saveAIVehicles: false
      };
      $scope.status = { level: 'info', message: '' };
      $scope.progress = { current: 0, total: 0, message: '' };
      $scope.confirm = { kind: null };

      function applySaves(res) {
        var list = res;
        if (typeof res === 'string') {
          try {
            list = JSON.parse(res);
          } catch (err) {
            list = [];
          }
        }
        if (list && list.saves) {
          list = list.saves;
        }
        if (!Array.isArray(list)) {
          list = [];
        }
        $scope.saves = list;
        $scope.status = {
          level: list.length ? 'success' : 'info',
          message: list.length ? ('Found ' + list.length + ' save' + (list.length === 1 ? '' : 's') + '.') : 'No .bngsave files found.'
        };
      }

      function callLua(fnName, args, callback) {
        args = args || [];
        var luaArgs = args.map(function (arg) {
          if (typeof arg === 'string') {
            return JSON.stringify(arg);
          }
          if (typeof arg === 'number' || typeof arg === 'boolean') {
            return String(arg);
          }
          return JSON.stringify(JSON.stringify(arg));
        }).join(',');
        var cmd = 'if not extensions.beamSave_core then extensions.load("beamSave_core") end; extensions.beamSave_core.' + fnName + '(' + luaArgs + ')';
        if (callback) {
          bngApi.engineLua(cmd, function (res) {
            if (!$scope.$$phase) {
              $scope.$apply(function () { callback(res); });
            } else {
              callback(res);
            }
          });
        } else {
          bngApi.engineLua(cmd);
        }
      }

      function ensureLoaded(thenFn) {
        bngApi.engineLua('if not extensions.beamSave_core then extensions.load("beamSave_core") end');
        if (thenFn) {
          thenFn();
        }
      }

      $scope.setTyping = function (on) {
        var flag = on ? 'true' : 'false';
        bngApi.engineLua('if setCEFTyping then setCEFTyping(' + flag + ') end');
        bngApi.engineLua('if setCEFFocus then setCEFFocus(' + flag + ') end');
        bngApi.engineLua('if core_input_bindings and core_input_bindings.setEnabled then core_input_bindings.setEnabled(' + (on ? 'false' : 'true') + ') end');
      };

      $scope.setLoadMode = function (mode) {
        $scope.settings.vehicleLoadMode = mode;
        $scope.saveSettings();
      };

      $scope.setTab = function (tab) {
        if ($scope.tab === 'save' && tab !== 'save') {
          $scope.setTyping(false);
        }
        $scope.tab = tab;
        if (tab === 'load') {
          $scope.refresh();
        }
        if (tab === 'settings') {
          callLua('getSettings');
        }
      };

      $scope.$on('$destroy', function () {
        $scope.setTyping(false);
      });

      $scope.progressPct = function () {
        if (!$scope.progress.total) {
          return 0;
        }
        return Math.max(0, Math.min(100, ($scope.progress.current / $scope.progress.total) * 100));
      };

      $scope.formatDate = function (iso) {
        if (!iso) {
          return '';
        }
        return String(iso).replace('T', ' ').replace(/:\d\d$/, '');
      };

      $scope.save = function () {
        if ($scope.busy || !$scope.saveName) {
          return;
        }
        callLua('saveScene', [$scope.saveName, false]);
      };

      $scope.refresh = function () {
        $scope.status = { level: 'info', message: 'Refreshing save list...' };
        callLua('listSaves');
      };

      $scope.load = function (save) {
        if (!save || save.corrupt || $scope.busy) {
          return;
        }
        callLua('loadSave', [save.path, false]);
      };

      $scope.askDelete = function (save) {
        $scope.confirm = {
          kind: 'deleteSave',
          title: 'Delete save?',
          text: 'Delete "' + save.saveName + '" and any beamstate files next to it? This cannot be undone.',
          ok: 'Delete',
          danger: true,
          save: save
        };
      };

      $scope.saveSettings = function () {
        callLua('updateSettings', [$scope.settings]);
      };

      $scope.cancelConfirm = function () {
        $scope.confirm = { kind: null };
      };

      $scope.acceptConfirm = function () {
        var kind = $scope.confirm.kind;
        var saveName = $scope.confirm.saveName;
        var savePath = $scope.confirm.savePath;
        var save = $scope.confirm.save;
        $scope.confirm = { kind: null };
        if (kind === 'overwrite') {
          callLua('saveScene', [saveName, true]);
        } else if (kind === 'deleteVehicles') {
          callLua('loadSave', [savePath, true]);
        } else if (kind === 'deleteSave' && save) {
          callLua('deleteSave', [save.path]);
        }
      };

      $scope.$on('BeamSaveUI', function (_, data) {
        if (!$scope.$$phase) {
          $scope.$apply(function () {
            handleEvent(data);
          });
        } else {
          handleEvent(data);
        }
      });

      function handleEvent(data) {
        if (!data || !data.type) {
          return;
        }
        if (data.type === 'status') {
          $scope.status = { level: data.level || 'info', message: data.message || '' };
        } else if (data.type === 'saves') {
          var list = data.saves || [];
          $scope.saves = list;
          $scope.status = {
            level: list.length ? 'success' : 'info',
            message: list.length
              ? ('Found ' + list.length + ' save' + (list.length === 1 ? '' : 's') + '.')
              : 'No .bngsave files found.'
          };
        } else if (data.type === 'settings' && data.settings) {
          Object.keys(data.settings).forEach(function (key) {
            $scope.settings[key] = data.settings[key];
          });
        } else if (data.type === 'busy') {
          $scope.busy = !!data.busy;
          if (!data.busy) {
            $scope.progress = { current: 0, total: 0, message: '' };
          } else if (data.message) {
            $scope.progress.message = data.message;
          }
        } else if (data.type === 'progress') {
          $scope.progress = {
            current: data.current || 0,
            total: data.total || 0,
            message: data.message || ''
          };
        } else if (data.type === 'confirmOverwrite') {
          $scope.confirm = {
            kind: 'overwrite',
            title: 'Overwrite save?',
            text: 'A save named "' + data.saveName + '" already exists. Replace it?',
            ok: 'Overwrite',
            danger: true,
            saveName: data.saveName
          };
        } else if (data.type === 'confirmDeleteVehicles') {
          $scope.confirm = {
            kind: 'deleteVehicles',
            title: 'Replace current vehicles?',
            text: 'This will delete the vehicles currently in the scene, then load the save.',
            ok: 'Replace and load',
            danger: true,
            savePath: data.savePath
          };
        }
      }

      ensureLoaded(function () {
        callLua('requestUIState');
      });
    }]
  };
}]);
