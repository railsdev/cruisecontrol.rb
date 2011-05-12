require 'test_helper'

require 'rexml/document'
require 'rexml/xpath'

class ProjectsControllerTest < ActionController::TestCase
  include FileSandbox
  include BuildFactory

  test "GET /projects.html renders HTML and assigns projects" do
    p1 = create_project_stub('one', 'success')
    p2 = create_project_stub('two', 'failed', [create_build_stub('1', 'failed')])
    Project.expects(:all).returns([p1, p2])
    stub_change_set_parser
    
    get :index
    assert_response :success
    assert_template "index"
    assert_equal %w(one two), assigns(:projects).map { |p| p.name }
  end
  
  test "XHR GET /projects.html renders the no_projects partial if there are no projects" do
    Project.expects(:all).returns []
    xhr :get, :index
    assert_response :success
    assert_tag :tag => 'div', :attributes => { :id => 'no_projects_help' }
  end

  test "XHR GET /projects.html renders the projects partial if projects are found" do
    p1 = create_project_stub('one', 'success')
    p2 = create_project_stub('two', 'failed', [create_build_stub('1', 'failed')])
    Project.expects(:all).returns([p1, p2])

    xhr :get, :index
    assert_response :success
    assert_tag :tag => 'div', :attributes => { :id => 'project_one' }
    assert_tag :tag => 'div', :attributes => { :id => 'project_two' }
  end

  test "GET /projects.rss renders XML based on retrieved projects" do
    Project.expects(:all).returns([
        create_project_stub('one', 'success', [create_build_stub('10', 'success')]),
        create_project_stub('two')])

    post :index, :format => 'rss'

    assert_response :success
    assert_template 'index_rss'
    assert_equal %w(one two), assigns(:projects).map { |p| p.name }

    xml = REXML::Document.new(@response.body)
    assert_equal "one build 10 success", REXML::XPath.first(xml, '/rss/channel/item[1]/title').text
    assert_equal "two has never been built", REXML::XPath.first(xml, '/rss/channel/item[2]/title').text
    assert_equal "<pre>bobby checked something in</pre>", REXML::XPath.first(xml, '/rss/channel/item[1]/description').text
    assert_equal "<pre></pre>", REXML::XPath.first(xml, '/rss/channel/item[2]/description').text
  end
  
  test "GET /projects.rss excludes incomplete builds" do
    Project.expects(:all).returns([
      create_project_stub('one', 'success', [create_build_stub('1', 'success')]),
      create_project_stub('two', 'incomplete', [create_build_stub('10', 'failed'), create_build_stub('11', 'incomplete')])
    ])
    post :index, :format => 'rss'
    
    xml = REXML::Document.new(@response.body)
    assert_equal "two build 10 failed", REXML::XPath.first(xml, '/rss/channel/item[2]/title').text
  end
  
  test "GET /project/:id.rss should return feed for a single project" do
    Project.expects(:find).with('one').returns(create_project_stub('one', 'success', [create_build_stub('10', 'success')]))
    get :show, :id => 'one', :format => 'rss'
    assert_response :success
    assert_template 'show_rss'
    
    xml = REXML::Document.new(@response.body)
    assert_equal "one build 10 success", REXML::XPath.first(xml, '/rss/channel/item[1]/title').text
  end

  test "GET /projects.html dashboard should render a link to each project" do
    Project.expects(:all).returns([create_project_stub('one', 'success')])
    get :index
    assert_tag :tag => "a", :attributes => {:href => /\/projects\/one/}, :content => "one"
  end
  
  test "GET /projects.html dashboard should render a button to start the builder if the builder is down" do
    project = create_project_stub('one', 'success')
    Project.stubs(:all).returns([project])
    
    project.stubs(:builder_down?).returns(true)
    get :index
    assert_tag :tag => "button", :content => /Start Builder/

    project.stubs(:builder_down?).returns(false)
    get :index
    assert_tag :tag => "button", :content => /Build Now/
  end

  test "GET /project/:id.html should redirect to the builds page for that project" do
    stub_project = Object.new
    Project.expects(:find).with('one').returns(stub_project)
    get :show, :id => 'one'
    assert_response :redirect
    assert_redirected_to :controller => "builds", :action => "show", :project => stub_project
  end

  test "GET /projects.cctray should render XML for each project" do
    Project.expects(:all).returns([
        create_project_stub('one', 'success', [create_build_stub('10', 'success')]),
        create_project_stub('two')])

    get :index, :format => 'cctray'

    assert_response :success
    assert_template 'index_cctray'
    assert_equal %w(one two), assigns(:projects).map { |p| p.name }
    
    xml = REXML::Document.new(@response.body)

    first_project = REXML::XPath.first(xml, '/Projects/Project[1]]')
    second_project = REXML::XPath.first(xml, '/Projects/Project[2]]')  

    assert_equal 'one', first_project.attributes['name']
    assert_equal 'Success', first_project.attributes['lastBuildStatus']
    assert_equal '10', first_project.attributes['lastBuildLabel']
    assert_equal 'Building', first_project.attributes['activity']
    assert_equal 'http://test.host/projects/one', first_project.attributes['webUrl']

    assert_equal 'two', REXML::XPath.first(xml, '/Projects/Project[2]]').attributes['name']
  end

  test "GET /projects.cctray should exclude XML for incomplete projects" do
    Project.expects(:all).returns([
        create_project_stub('one', 'failed', [create_build_stub('10', 'failed'), create_build_stub('11', 'incomplete')])
        ])

    post :index, :format => 'cctray'

    xml = REXML::Document.new(@response.body)
    assert_equal 'one', REXML::XPath.first(xml, '/Projects/Project[1]]').attributes['name']
    assert_equal 'Failure', REXML::XPath.first(xml, '/Projects/Project[1]]').attributes['lastBuildStatus']
    assert_equal '10', REXML::XPath.first(xml, '/Projects/Project[1]').attributes['lastBuildLabel']
    assert_equal 'Building', REXML::XPath.first(xml, '/Projects/Project[1]]').attributes['activity']
  end

  test "GET /projects/:id/*:path should returh the code for that file" do
    in_sandbox do |sandbox|
      project = create_project "three"
      sandbox.new :file => 'projects/three/work/app/controller/FooController.rb', :with_contents => "class FooController\nend\n"
    
      get :code, :id => 'three', :path => ['app', 'controller', 'FooController.rb'], :line => 2

      assert_response :success
      assert_match /class FooController/, @response.body
    end
  end

  test "GET /projects/:id/*:path for a project that doesn't exist should render a 404" do
    Project.expects(:find).with('foo').returns(nil)
    get :code, :id => 'foo', :path => ['foo.rb'], :line => 1
    assert_response 404
  end

  test "GET /projects/:id/*:path for a path that doesn't exist should render a 404" do
    in_sandbox do |sandbox|
      project = create_project "project"

      get :code, :id => 'project', :path => ['foo.rb'], :line => 1
      assert_response 404
    end
  end

  test "POST /projects/:id/build should build the requested project" do
    project = create_project_stub('two')
    Project.expects(:find).with('two').returns(project)
    project.expects(:request_build)
    Project.stubs(:all).returns [ project ]
    post :build, :id => "two"
    assert_response :redirect
    assert_equal 'two', assigns(:project).name
  end
  
  test "POST /projects/:id/build should render a 404 if the requested project does not exist" do
    Project.expects(:find).with('non_existing_project').returns(nil)
    post :build, :id => "non_existing_project"
    assert_response 404
  end

  test "XHR POST /projects/:id/build should render the projects partial after a successful build" do
    project = create_project_stub('two')
    Project.expects(:find).with('two').returns(project)
    project.expects(:request_build)
    Project.stubs(:all).returns [ project ]

    xhr :post, :build, :id => "two"

    assert_response :success
    assert_tag 'div', :attributes => { :id => 'project_two' }
  end
  
  test "GET /projects/:id.html should render a 404 if the requested project does not exist" do
    Project.expects(:find).with('non_existing_project').returns(nil)
    post :show, :id => "non_existing_project", :format => 'rss'
    assert_response 404
    assert_equal 'Project "non_existing_project" not found', @response.body
  end

  test "GET /projects.html should render disabled build buttons if the project cannot build now" do
    stub_project = create_project_stub('one', 'success')
    stub_project.stubs(:can_build_now?).returns(false)
    
    Project.expects(:all).returns([ stub_project ])
    get :index
    assert_tag :tag => "button", :attributes => {:disabled => "disabled"}
  end

  test "POST /projects/:id/build should refuse to build and render a 403 if the configuration does not permit build now" do
    Configuration.stubs(:disable_build_now).returns(true)

    get :build, :id => 'one'
    
    assert_response 403
    assert_equal 'Build requests are not allowed', @response.body
  end

  test "POST /projects should create a new project" do
    in_sandbox do
      scm = stub("FakeSourceControl")

      FakeSourceControl.expects(:new).returns scm
      Project.expects(:create).with("new_project", scm).returns stub(:id => "some_project")
      post :create, :project => { :name => "new_project", :source_control => { :source_control => "fake_source_control", :repository => "file:///foo" } }
    end
  end

  test "POST /projects should redirect to the new project guide on successful create" do
    in_sandbox do
      SourceControl.stubs(:create)
      Project.stubs(:create).returns stub(:id => "new_project")

      post :create, :project => { :source_control => {} }
      assert_redirected_to getting_started_project_path("new_project")
    end
  end

  def stub_change_set_parser
    mock = Object.new
    SourceControl::Subversion::ChangesetLogParser.stubs(:new).returns(mock)
    mock.expects(:parse_log).returns([])
  end

end
